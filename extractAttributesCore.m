function result = extractAttributesCore(subsystemHandle, searchFolder, outputFile, options)
%EXTRACTATTRIBUTESCORE Scan .m files for attribute records matching subsystem port names.
%
%   result = extractAttributesCore(subsystemHandle, searchFolder, outputFile, options)
%
% INPUTS:
%   subsystemHandle - Numeric handle to the Simulink subsystem
%   searchFolder    - Parent folder containing .m files to scan (recursive)
%   outputFile      - Destination .m file path
%   options         - Struct with fields:
%       .PortChoice            : 'Inports' | 'Outports' | 'Both'
%       .IncludeMetadata       : true | false
%       .IncludeSourceComments : true | false
%       .CaseInsensitive       : true | false
%       .ProgressFcn           : (optional) @(fraction, message)
%       .CancelRequestedFcn    : (optional) @() -> true | false
%
% OUTPUT:
%   result - Struct matching teamtools expectations.

    % --- Validate inputs ---------------------------------------------------
    if isempty(subsystemHandle) || ~isnumeric(subsystemHandle) || ...
            ~isscalar(subsystemHandle) || subsystemHandle <= 0
        error('extractAttributesCore:InvalidHandle', ...
            'A valid numeric subsystem handle is required.');
    end
    if ~isfolder(searchFolder)
        error('extractAttributesCore:InvalidFolder', ...
            'Search folder does not exist: %s', searchFolder);
    end

    % --- Resolve port names from the subsystem -----------------------------
    [inportNames, outportNames] = getImmediatePortNames(subsystemHandle);

    switch options.PortChoice
        case 'Inports'
            searchTags = inportNames;
        case 'Outports'
            searchTags = outportNames;
        otherwise  % 'Both'
            searchTags = unique([inportNames(:); outportNames(:)], 'stable');
            searchTags = searchTags(:).';
    end

    if isempty(searchTags)
        error('extractAttributesCore:NoPorts', ...
            'No immediate %s found in the selected subsystem.', ...
            lower(options.PortChoice));
    end

    % --- Build the full options struct -------------------------------------
    fullOpts = options;
    fullOpts.InportNames  = inportNames;
    fullOpts.OutportNames = outportNames;

    % --- Run the scan-and-write engine -------------------------------------
    result = runExtraction(subsystemHandle, searchTags, searchFolder, ...
        outputFile, fullOpts);
end

%% ========================================================================
%%  CORE SCAN-AND-WRITE ENGINE
%% ========================================================================
function result = runExtraction(subsystemHandle, searchTags, ...
        searchFolder, outputFile, options)

    result = struct( ...
        'Subsystem',     getfullname(subsystemHandle), ...
        'PortChoice',    options.PortChoice, ...
        'FilesFound',    0, ...
        'FilesRead',     0, ...
        'FilesSkipped',  0, ...
        'UniqueMatches', 0, ...
        'OutputFile',    outputFile, ...
        'Tags',          struct('Name', {}, 'Count', {}), ...
        'Warnings',      {{}}, ...
        'Cancelled',     false);

    % --- Discover .m files -------------------------------------------------
    matlabFiles = dir(fullfile(searchFolder, '**', '*.m'));
    matlabFiles = matlabFiles(~[matlabFiles.isdir]);

    % Exclude the output file itself from scanning
    keepMask = true(size(matlabFiles));
    for idx = 1:numel(matlabFiles)
        candidate = fullfile(matlabFiles(idx).folder, matlabFiles(idx).name);
        if strcmpi(candidate, outputFile)
            keepMask(idx) = false;
        end
    end
    matlabFiles = matlabFiles(keepMask);
    result.FilesFound = numel(matlabFiles);

    % --- Build Dual-Tag Mapping lookup map ---------------------------------
    % Maps both the raw port name and its valid variable name back to the original raw port name
    tagLookup = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for idx = 1:numel(searchTags)
        rawTag = strtrim(searchTags{idx});
        cleanTag = matlab.lang.makeValidName(rawTag);
        
        keyRaw = rawTag;
        keyClean = cleanTag;
        if options.CaseInsensitive
            keyRaw = lower(keyRaw);
            keyClean = lower(keyClean);
        end
        
        tagLookup(keyRaw) = rawTag;
        tagLookup(keyClean) = rawTag;
    end

    % --- Containers for unique records -------------------------------------
    recordMap   = containers.Map('KeyType', 'char', 'ValueType', 'any');
    recordOrder = {};
    filesRead   = 0;

    % --- Scan every .m file ------------------------------------------------
    for fileIdx = 1:numel(matlabFiles)

        % Progress / cancel check
        if checkCancel(options)
            result.Cancelled = true;
            return;
        end
        reportProgress(options, fileIdx / max(1, numel(matlabFiles)), ...
            sprintf('Reading file %d of %d...', fileIdx, numel(matlabFiles)));

        sourceFile = fullfile(matlabFiles(fileIdx).folder, ...
            matlabFiles(fileIdx).name);
        fid = fopen(sourceFile, 'rt');
        if fid == -1
            result.Warnings{end + 1} = ...
                sprintf('Could not open: %s', sourceFile); %#ok<AGROW>
            continue;
        end
        filesRead = filesRead + 1;
        cleanupObj = onCleanup(@() fclose(fid));
        lineNum = 0;

        while true
            rawLine = fgetl(fid);
            if ~ischar(rawLine)
                break;
            end
            lineNum = lineNum + 1;
            record = strtrim(rawLine);

            % Skip blanks and full-line comments
            if isempty(record) || startsWith(record, '%')
                continue;
            end

            % Must contain a dot (Tag.Property = value)
            dotPos = find(record == '.', 1, 'first');
            if isempty(dotPos) || dotPos == 1
                continue;
            end

            tag = strtrim(record(1:dotPos - 1));
            if options.CaseInsensitive
                lookupTag  = lower(tag);
                dedupKey   = lower(record);
            else
                lookupTag  = tag;
                dedupKey   = record;
            end

            if ~isKey(tagLookup, lookupTag)
                continue;
            end

            % Map the matched tag back to the exact original port name
            matchedPortName = tagLookup(lookupTag);

            % Skip lines that are Simulink.Signal instantiations
            if isSignalInstantiation(record, tag)
                continue;
            end

            relSource = makeRelativePath(sourceFile, searchFolder);
            sourceStr = sprintf('%s (line %d)', relSource, lineNum);

            if ~isKey(recordMap, dedupKey)
                recordMap(dedupKey) = struct( ...
                    'Record',  record, ...
                    'Sources', {{sourceStr}}, ...
                    'Tag',     matchedPortName);
                recordOrder{end + 1} = dedupKey; %#ok<AGROW>
            else
                item = recordMap(dedupKey);
                if ~any(strcmp(item.Sources, sourceStr))
                    item.Sources{end + 1} = sourceStr;
                    recordMap(dedupKey) = item;
                end
            end
        end
        clear cleanupObj;
    end

    result.FilesRead   = filesRead;
    result.FilesSkipped = result.FilesFound - filesRead;

    % --- Compute per-tag counts --------------------------------------------
    tagCounts = zeros(numel(searchTags), 1);
    for recIdx = 1:numel(recordOrder)
        item = recordMap(recordOrder{recIdx});
        for tagIdx = 1:numel(searchTags)
            if options.CaseInsensitive
                match = strcmpi(item.Tag, searchTags{tagIdx});
            else
                match = strcmp(item.Tag, searchTags{tagIdx});
            end
            if match
                tagCounts(tagIdx) = tagCounts(tagIdx) + 1;
                break;
            end
        end
    end
    tagStructs = struct('Name', cell(1, 0), 'Count', cell(1, 0));
    for tagIdx = 1:numel(searchTags)
        tagStructs(end + 1) = struct( ...
            'Name', searchTags{tagIdx}, ...
            'Count', tagCounts(tagIdx)); %#ok<AGROW>
    end
    result.Tags = tagStructs;

    % --- Write the output file ---------------------------------------------
    reportProgress(options, 1.0, 'Writing output file...');

    outId = fopen(outputFile, 'wt');
    if outId == -1
        error('extractAttributesCore:OutputOpenFailed', ...
            'Could not create the destination file: %s', outputFile);
    end
    outCleanup = onCleanup(@() fclose(outId));

    % Metadata header formatting aligned with AttributeExtractorGUI
    if options.IncludeMetadata
        fprintf(outId, '%% Auto-generated by AttributeExtractorGUI.m\n');
        fprintf(outId, '%% Generated on: %s\n', datestr(now, 31));
        fprintf(outId, '%% Selected subsystem: %s\n', ...
            getfullname(subsystemHandle));
        fprintf(outId, '%% Port selection: %s\n', options.PortChoice);
        fprintf(outId, '%% Search directory: %s\n', searchFolder);
        fprintf(outId, '%% MATLAB files successfully scanned: %d\n', filesRead);
        fprintf(outId, '%% Search tags: %d\n', numel(searchTags));
        fprintf(outId, '%% Unique matching records: %d\n', ...
            numel(recordOrder));
        fprintf(outId, '\n');
    end

    % Inport set for classification
    inportSet = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    for idx = 1:numel(options.InportNames)
        inportSet(options.InportNames{idx}) = true;
    end

    % Inports section grouping
    if any(strcmp(options.PortChoice, {'Inports', 'Both'}))
        inTags = searchTags(cellfun(@(t) isKey(inportSet, t), searchTags));
        if ~isempty(inTags)
            fprintf(outId, ...
                '%% ===================== Inports =====================\n\n');
            writePortBlocks(outId, inTags, recordMap, recordOrder, options);
        end
    end

    % Outports section grouping
    if any(strcmp(options.PortChoice, {'Outports', 'Both'}))
        outTags = searchTags(~cellfun(@(t) isKey(inportSet, t), searchTags));
        if ~isempty(outTags)
            fprintf(outId, ...
                '%% ===================== Outports ====================\n\n');
            writePortBlocks(outId, outTags, recordMap, recordOrder, options);
        end
    end

    clear outCleanup;
    result.UniqueMatches = numel(recordOrder);
end

%% ========================================================================
%%  WRITE PORT BLOCKS  (declaration + interleaved attributes)
%% ========================================================================
function writePortBlocks(outId, portTags, recordMap, recordOrder, options)
    for tagIdx = 1:numel(portTags)
        portName = portTags{tagIdx};
        cleanVar = matlab.lang.makeValidName(portName);

        % Camelcase declaration syntax identical to target AttributeExtractorGUI format
        fprintf(outId, '%s = Simulink.Signal;\n', cleanVar);

        % Interleave matching attribute records directly underneath
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
                        fprintf(outId, '%% Source:\n');
                    else
                        fprintf(outId, '%% Sources:\n');
                    end
                    for srcIdx = 1:numel(item.Sources)
                        fprintf(outId, '%%   %s\n', item.Sources{srcIdx});
                    end
                end
                fprintf(outId, '%s\n', item.Record);
                if options.IncludeSourceComments
                    fprintf(outId, '\n');
                end
            end
        end
        fprintf(outId, '\n');
    end
end

%% ========================================================================
%%  HELPERS
%% ========================================================================
function tf = isSignalInstantiation(record, tag)
    tf = false;
    remainder = strtrim(record(length(tag) + 1:end));
    if ~isempty(regexp(remainder, '^=\s*Simulink\.Signal\s*;', 'once'))
        tf = true;
    end
end

function [inportNames, outportNames] = getImmediatePortNames(subsystemHandle)
    commonOpts = {'LookUnderMasks', 'on', 'FollowLinks', 'on', ...
        'SearchDepth', 1};
    inHandles  = find_system(subsystemHandle, commonOpts{:}, ...
        'BlockType', 'Inport');
    outHandles = find_system(subsystemHandle, commonOpts{:}, ...
        'BlockType', 'Outport');
    inportNames  = normalizeBlockNames(inHandles);
    outportNames = normalizeBlockNames(outHandles);
end

function names = normalizeBlockNames(blockHandles)
    if isempty(blockHandles)
        names = {};
        return;
    end
    names = get_param(blockHandles, 'Name');
    if ischar(names)
        names = {names};
    end
    names = cellfun(@strtrim, names, 'UniformOutput', false);
    names = names(~cellfun('isempty', names));
    names = unique(names, 'stable');
    names = names(:).';
end

function relPath = makeRelativePath(fullPath, rootFolder)
    rootSep = [char(rootFolder) filesep];
    if strncmpi(fullPath, rootSep, numel(rootSep))
        relPath = fullPath(numel(rootSep) + 1:end);
    else
        relPath = fullPath;
    end
end

function reportProgress(options, fraction, message)
    if isfield(options, 'ProgressFcn') && ~isempty(options.ProgressFcn)
        try
            options.ProgressFcn(fraction, message);
        catch
        end
    end
end

function tf = checkCancel(options)
    tf = false;
    if isfield(options, 'CancelRequestedFcn') && ...
            ~isempty(options.CancelRequestedFcn)
        try
            tf = logical(options.CancelRequestedFcn());
        catch
        end
    end
end