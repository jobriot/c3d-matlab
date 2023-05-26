function points_st = open_c3d(file)
	fid = fopen(file, 'rb');
	if (fid < 0)
		error('Failed to open C3D file');
	end


	% initially used these functions as I took the header as one block but starting at the parameters section everything is read sequentially
	function byte = word2b(word)
		byte = 2*word - 1;
	end
	function w = wordint(header, word)
		w = header(word2b(word)) + header(word2b(word)+1)*256;
	end
	function ar = wordheader(header, start_word, nb_bytes)
		ar = zeros(1,nb_bytes);
		for i = 1:nb_bytes
			ar(i) = header(2*start_word-1 + i - 1);
		end
	end
	function w = word2float(header, word)
		ar = wordheader(header, word, 4); % 32bits float, 2 words, 4 bytes
		w = typecast(uint8(ar),'single');
	end

	% HEADER

	% Read the header information of the C3D file
	fseek(fid, 0, 'bof');
	header = fread(fid, 512, 'int8');

	% functions expect the index of words starting from 1
	% word(n) returns the index of the first byte of the nth word
	% wordint converts a full word to int
	% word2float converts 2 words to a 32bits float

	nb_markers = wordint(header, 2);
	nb_an_sample = wordint(header, 3);

	first_frame = wordint(header, 4);
	last_frame = wordint(header, 5);
	nb_frame = last_frame - first_frame + 1;

	max_frame_interpolation = wordint(header, 6);

	units_factor = word2float(header, 7);

	pointer_parameter = header(word2b(1));  % pointers probably won't be used since the file is read sequentially
	pointer_storage = wordint(header, 9);   % only really useful to determine the number of blocks a section takes

	four_char_support = wordint(header, 150) == 0x3039; % not sure what's the layout if it's only 2 char

	% TODO support for legacy files
	if (~four_char_support)
		error('four char support is required');
	end

	analog_sample_rate = wordint(header, 10);
	frame_rate = word2float(header, 11);

	event_nb = wordint(header, 151);
	event_times = [];
	for i = 0:event_nb-1
		event_times(i+1) = word2float(header, 153 + i*2);
	end
	event_display_flags = [];
	for i = 0:event_nb-1
		event_display_flags(i+1) = header(word2b(189) + i);
	end
	event_names = repmat('0000', event_nb, 1);
	for i = 0:event_nb-1
		for j = 0:3
			event_names(i+1,j+1) = header(word2b(199) + i*4 + j);
		end
	end

	% variables in order of documentation

	% pointer_parameter       1 (2nd byte not implemented)
	% nb_markers              2
	% nb_an_sample            3
	% first_frame             4
	% last_frame              5
	% nb_frame
	% max_frame_interpolation 6
	% units_factor            7-8
	% pointer_storage         9
	% analog_sample_rate      10
	% frame_rate              11-12
	%                         13-149 unused
	% four_char_support            150
	% event_nb                151
	%                         152 unused
	% event_times             153-188
	% event_display_flags     189-197
	%                         198 unused
	% event_names             199-234
	%                         235-256 unused

	% for event_names, the strings are accessed like so : event_names(index,:)


	% PARAMETER

	param_h = fread(fid, 4, 'int8');

	% number of blocks
	n_block = param_h(3);

	% should be used to determine floating point type or whatever, TODO
	% will be a nightmare :)
	proc = param_h(4);


	groups = struct();
	id2name = struct();

	cond = 1;

	while (cond ~= 0)
		param_i = fread(fid, 2, 'int8');
		n_name = abs(param_i(1));
		id = param_i(2);
		param_i_name = fread(fid, n_name, '*char').';

		if (id < 0)
			groups.(param_i_name) = struct("id", abs(id), "parameters", struct());
			id2name.(strcat("L", num2str(abs(id)))) = param_i_name;
			offset = fread(fid, 1, 'uint16');
			cond = abs(offset);
			param_d = fread(fid, 1, 'int8');
			if (param_d > 0)
				groups.(param_i_name).("description") = fread(fid, param_d, '*char').';
			else
				groups.(param_i_name).("description") = "";
			end
			fseek(fid, cond - (param_d + 3), 0);
		elseif (id == 0)
			break
		else
			groups.(id2name.(strcat("L", num2str(id)))).("parameters").(param_i_name) = struct();
			offset = fread(fid, 1, 'uint16');
			cond = abs(offset);

			data_length = fread(fid, 1, 'int8');
			switch data_length
				case -1
					type = "*char";
				case 1
					type = "int8";
				case 2
					type = "int16";
				case 4
					type = "single";
			end

			addition = 0;

			n_dim = fread(fid, 1, 'int8');
			if (n_dim > 0)
				dims = fread(fid, n_dim, 'int8');
				r = fread(fid, prod(dims), type);
				if (n_dim > 1)
					te = reshape(r, dims.');
					te = pagetranspose(te); % not sure but the idea is the reshape "row"-based, still not sure what the behavior would be for more than 2 dimentions...
					groups.(id2name.(strcat("L", num2str(id)))).("parameters").(param_i_name).("data") = te;
				else
					groups.(id2name.(strcat("L", num2str(id)))).("parameters").(param_i_name).("data") = r;
				end
				addition = prod(dims) * abs(data_length) + n_dim;
			else
				groups.(id2name.(strcat("L", num2str(id)))).("parameters").(param_i_name).("data") = fread(fid, 1, type);
				addition = abs(data_length);
			end


			param_d = fread(fid, 1, 'int8');
			if (param_d > 0)
				groups.(id2name.(num2str(id))).("parameters").(param_i_name).("description") = fread(fid, param_d, '*char').';
			else
				groups.(id2name.(strcat("L", num2str(id)))).("parameters").(param_i_name).("description") = "";
			end
			fseek(fid, cond - (param_d + 3 + addition + 2), 0); % useless but in case there's a size mismatch I guess...
		end
	end

	% to check variable's content
	% js = fopen('parameter.json','w');
	% fprintf(js, jsonencode(groups));
	% fclose(js);

	% SHOULD REVIEW EVERY POSSIBLE PARAMETER
	% SHOULD ALSO CHECK FOR THE PRESENCE OF REQUIRED PARAMETERS







	% 3D POINTS

	fseek(fid, (groups.('POINT').('parameters').('DATA_START').('data') - 1) * 512, -1);


	% depending on the sign of POINT:SCALE, the values of 3D points are either stored as signed integer or floating point
	pscale = groups.('POINT').('parameters').('SCALE').('data');
	isfp = pscale < 0;
	if (isfp)
		format = 'single';
	else
		format = 'int16';
	end

	% for now, only the single (floating point) is expected to work

	points = struct();
	nb_points = groups.('POINT').('parameters').('USED').('data');
	point_rate = groups.('POINT').('parameters').('RATE').('data');
	nb_analog = groups.('ANALOG').('parameters').('USED').('data');
	analog_rate = groups.('ANALOG').('parameters').('RATE').('data');
	analog_offset = groups.('ANALOG').('parameters').('OFFSET').('data');
	analog_scale = groups.('ANALOG').('parameters').('SCALE').('data');
	analog_genscale = groups.('ANALOG').('parameters').('GEN_SCALE').('data');

	if (isfield(groups.('ANALOG').('parameters'), 'FORMAT'))
		analog_format = groups.('ANALOG').('parameters').('FORMAT').('data');
		warning("ANALOG:FORMAT found, this is not yet supported if the format is unusual");
	end
	if (isfield(groups.('ANALOG').('parameters'), 'BITS'))
		analog_bits = groups.('ANALOG').('parameters').('BITS').('data');
		warning("ANALOG:BITS found, this is not yet supported if the format is unusual");
	end

	nb_ana_per_frame = analog_rate / point_rate;

	nb_frames = groups.('POINT').('parameters').('FRAMES').('data');
	vect_pts = zeros(nb_frames, nb_points, 3);
	vect_ana = zeros(nb_frames, nb_ana_per_frame, nb_analog);

	for i = 1:nb_frames
		if (isfp)
			for j = 1:nb_points
				vect_pts(i, j, :) = fread(fid, 3, 'single');
				fseek(fid, 4, 0); % camera mask, not yet used
			end
		else
			for j = 1:nb_points
				vect_pts(i, j, :) = fread(fid, 3, 'int16') * abs(pscale);
				fseek(fid, 4, 0); % camera mask, not yet used
			end
		end
		for j = 1:nb_ana_per_frame
			if (isfp)
				vect_ana(i, j, :) = (fread(fid, nb_analog, 'single') - analog_offset) .* analog_scale * analog_genscale;
			else
				vect_ana(i, j, :) = (fread(fid, nb_analog, 'int16') - analog_offset) .* analog_scale * analog_genscale;
			end
		end
	end

	points_st = struct();

	for i = 1:nb_points
		lab = strtrim(groups.('POINT').('parameters').('LABELS').('data')(i,:));
		% EVIL
		try
			points_st.('point').(lab) = squeeze(vect_pts(:, i, :));
		end
		points_st.('noms'){i} = lab;
	end
	for i = 1:nb_analog
		try
			points_st.('analog').(strtrim(groups.('ANALOG').('parameters').('LABELS').('data')(i,:))) = vect_ana(:, :, i);
		end
	end

	% for compliance with other libraries
	points_st.('coord') = zeros(nb_frames, nb_points * 3);
	for i = 1:nb_frames
		for j = 1:nb_points
			for k = 1:3
				points_st.('coord')(i, (j-1)*3 + k) = vect_pts(i, j, k);
			end
		end
	end

	% to check variable's content
	% js = fopen('points.json','w');
	% fprintf(js, jsonencode(points_st));
	% fclose(js);


	fclose(fid);
end
