function result = extractRecords(subsystemHandle, searchTags, ...
        searchFolder, outputFile, options, progress)
%EXTRACTRECORDS Scan .m files and generate a grouped, deduplicated output file.

    result = struct( ...
        'Subsystem', getfullname(subsystemHandle), ...
        'PortChoice', options.PortChoice, ...
        'InformationChoice', options.InformationChoice, ...
        'SearchTagCount', numel(searchTags), ...
        'FilesScanned', 0, ...
        'UniqueMatches', 0, ...
        'OutputFile', outputFile, ...
        'Cancelled', false);

    matlabFiles = dir(fullfile(searchFolder, '**', '*.m'));
    matlabFiles = matlabFiles(~[matlabFiles.isdir]);

    % Exclude the output file itself from scanning
    keepFile = true(size(matlabFiles));
    for index = 1:numel(matlabFiles)
        candidate = fullfile(matlabFiles(index).folder, matlabFiles(index).name);
        if strcmpi(candidate, outputFile)
            keepFile(index) = false;
        end
    end
    matlabFiles = matlabFiles(keepFile);

    % Build a lookup map of valid tags (port names)
    tagLookup = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    for index = 1:numel(searchTags)
        key = strtrim(searchTags{index});
        if options.CaseInsensitive
            key = lower(key);
        end
        tagLookup(key) = true;
    end

    % Store unique records with their source info and original tag
    recordMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
    recordOrder = {};
    filesRead = 0;

    if ~isempty(progress)
        progress.Indeterminate = 'off';
    end

    % --- Scan all .m files ---
    for fileIndex = 1:numel(matlabFiles)
        if ~isempty(progress)
            if progress.CancelRequested
                result.Cancelled = true;
                error('AttributeExtractorGUI:Cancelled', ...
                    'Extraction was cancelled by the user.');
            end
            progress.Value = fileIndex / max(1, numel(matlabFiles));
            progress.Message = sprintf('Reading file %d of %d...', ...
                fileIndex, numel(matlabFiles));
            drawnow limitrate;
        end

        sourceFile = fullfile(matlabFiles(fileIndex).folder, ...
            matlabFiles(fileIndex).name);
        inputId = fopen(sourceFile, 'rt');
        if inputId == -1
            warning('AttributeExtractorGUI:FileOpenFailed', ...
                'Could not read file: %s', sourceFile);
            continue;
        end

        filesRead = filesRead + 1;
        inputCleanup = onCleanup(@() fclose(inputId));
        lineNumber = 0;

        while true
            rawLine = fgetl(inputId);
            if ~ischar(rawLine)
                break;
            end

            lineNumber = lineNumber + 1;
            record = strtrim(rawLine);

            % Skip empty lines and full-line comments
            if isempty(record) || startsWith(record, '%')
                continue;
            end

            dotPosition = find(record == '.', 1, 'first');
            if isempty(dotPosition) || dotPosition == 1
                continue;
            end

            tag = strtrim(record(1:dotPosition - 1));
            if options.CaseInsensitive
                lookupTag = lower(tag);
                duplicateKey = lower(record);
            else
                lookupTag = tag;
                duplicateKey = record;
            end

            if ~isKey(tagLookup, lookupTag)
                continue;
            end

            % ---------------------------------------------------------------
            % FILTER: Skip lines that are Simulink.Signal instantiations
            % (e.g., "car = Simulink.Signal;") since we generate those.
            % ---------------------------------------------------------------
            if isSignalInstantiation(record, tag)
                continue;
            end

            relativeSource = makeRelativePath(sourceFile, searchFolder);
            source = sprintf('%s (line %d)', relativeSource, lineNumber);

            if ~isKey(recordMap, duplicateKey)
                recordMap(duplicateKey) = struct( ...
                    'Record', record, ...
                    'Sources', {{source}}, ...
                    'Tag', tag);
                recordOrder{end + 1} = duplicateKey; %#ok<AGROW>
            else
                item = recordMap(duplicateKey);
                if ~any(strcmp(item.Sources, source))
                    item.Sources{end + 1} = source;
                    recordMap(duplicateKey) = item;
                end
            end
        end
        clear inputCleanup;
    end

    % --- Write output file ---
    if ~isempty(progress)
        progress.Message = 'Writing output file...';
        drawnow;
    end

    outputId = fopen(outputFile, 'wt');
    if outputId == -1
        error('AttributeExtractorGUI:OutputOpenFailed', ...
            'Could not create the destination file: %s', outputFile);
    end
    outputCleanup = onCleanup(@() fclose(outputId));

    % 1. Write metadata header (if requested)
    if options.IncludeMetadata
        fprintf(outputId, '%% Auto-generated by AttributeExtractorGUI.m\n');
        fprintf(outputId, '%% Generated on: %s\n', datestr(now, 31));
        fprintf(outputId, '%% Selected subsystem: %s\n', ...
            getfullname(subsystemHandle));
        fprintf(outputId, '%% Port selection: %s\n', options.PortChoice);
        fprintf(outputId, '%% Output information: %s\n', ...
            options.InformationChoice);
        fprintf(outputId, '%% Search directory: %s\n', searchFolder);
        fprintf(outputId, '%% MATLAB files successfully scanned: %d\n', ...
            filesRead);
        fprintf(outputId, '%% Search tags: %d\n', numel(searchTags));
        fprintf(outputId, '%% Unique matching records: %d\n', ...
            numel(recordOrder));
        fprintf(outputId, '\n');
    end

    % 2. Determine which tags are inports vs outports
    inportSet = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    for idx = 1:numel(options.InportNames)
        inportSet(options.InportNames{idx}) = true;
    end

    % 3. Write Inport section
    if any(strcmp(options.PortChoice, {'Inports', 'Both'}))
        inportTags = searchTags(cellfun(@(t) isKey(inportSet, t), searchTags));
        if ~isempty(inportTags)
            fprintf(outputId, '%% ===================== Inports =====================\n\n');
            writePortBlocks(outputId, inportTags, recordMap, recordOrder, options);
        end
    end

    % 4. Write Outport section
    if any(strcmp(options.PortChoice, {'Outports', 'Both'}))
        outportTags = searchTags(~cellfun(@(t) isKey(inportSet, t), searchTags));
        if ~isempty(outportTags)
            fprintf(outputId, '%% ===================== Outports ====================\n\n');
            writePortBlocks(outputId, outportTags, recordMap, recordOrder, options);
        end
    end

    clear outputCleanup;

    result.FilesScanned = filesRead;
    result.UniqueMatches = numel(recordOrder);
end

%% ========================================================================
%% WRITE PORT BLOCKS (declaration + attributes per port)
%% ========================================================================
function writePortBlocks(outputId, portTags, recordMap, recordOrder, options)
    for tagIdx = 1:numel(portTags)
        portName = portTags{tagIdx};
        cleanVarName = matlab.lang.makeValidName(portName);

        % Write the signal declaration
        fprintf(outputId, '%s = Simulink.Signal;\n', cleanVarName);

        % Find and write all extracted attribute records for this port
        for recIdx = 1:numel(recordOrder)
            item = recordMap(recordOrder{recIdx});

            if options.CaseInsensitive
                match = strcmpi(item.Tag, portName);
            else
                match = strcmp(item.Tag, portName);
            end

            if match
                if options.IncludeSourceComments
                    if numel(item.Sources) == 1
                        fprintf(outputId, '%% Source:\n');
                    else
                        fprintf(outputId, '%% Sources:\n');
                    end
                    for sourceIndex = 1:numel(item.Sources)
                        fprintf(outputId, '%%   %s\n', item.Sources{sourceIndex});
                    end
                end
                fprintf(outputId, '%s\n', item.Record);
            end
        end

        % Blank line after each port block
        fprintf(outputId, '\n');
    end
end

%% ========================================================================
%% CHECK IF A LINE IS A SIMULINK.SIGNAL INSTANTIATION
%% ========================================================================
function tf = isSignalInstantiation(record, tag)
%ISSIGNALINSTANTIATION Return true if the record is just "tag = Simulink.Signal;"
%   This prevents duplicating the declaration that the code already generates.

    tf = false;

    % Remove the tag prefix and the dot (if any) — but instantiation lines
    % typically look like "car = Simulink.Signal;" with no dot.
    % However, the scanner only passes lines WITH a dot, so check for
    % patterns like "car.Signal = ..." which is unlikely. The real case is
    % when the source file has "car = Simulink.Signal;" and the dot is in
    % "Simulink.Signal". In that case tag = "car" and the remainder after
    % "car" contains "= Simulink.Signal;".

    % Strip the tag from the beginning
    remainder = strtrim(record(length(tag) + 1:end));

    % Check if remainder matches "= Simulink.Signal;" (with optional spaces)
    if ~isempty(regexp(remainder, '^=\s*Simulink\.Signal\s*;', 'once'))
        tf = true;
    end
end