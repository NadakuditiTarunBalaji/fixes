function result = extractAttributesCore(subsystemHandle, searchFolder, outputFile, options)
%EXTRACTATTRIBUTESCORE Scan .m files for records tagged by subsystem ports.

if nargin < 4 || isempty(options)
    options = struct();
end
options = fillDefaults(options, struct( ...
    'PortChoice',            'Both', ...
    'IncludeMetadata',       true, ...
    'IncludeSourceComments', true, ...
    'CaseInsensitive',       true, ...
    'ProgressFcn',           @(~, ~) [], ...
    'CancelRequestedFcn',    @false));

progressFcn = options.ProgressFcn;
cancelFcn = options.CancelRequestedFcn;

result = struct( ...
    'Subsystem',      '', ...
    'PortChoice',     options.PortChoice, ...
    'Tags',           struct('Name', {}, 'Count', {}), ...
    'SearchTagCount', 0, ...
    'FilesFound',     0, ...
    'FilesRead',      0, ...
    'FilesSkipped',   0, ...
    'UniqueMatches',  0, ...
    'OutputFile',     '', ...
    'Cancelled',      false, ...
    'Warnings',       {{}});

% HIGH-SEVERITY FIX: Safe handle check including 0 (root model)
if isempty(subsystemHandle)
    subsystemHandle = gcbh;
end

if isempty(subsystemHandle) || ~isnumeric(subsystemHandle) || ...
        ~isscalar(subsystemHandle) || subsystemHandle == 0 || subsystemHandle == -1
    error('extractAttributesCore:NoSelection', ...
        ['No Simulink subsystem is selected. Open the model and click the ', ...
         'required subsystem first.']);
end

try
    blockType = get_param(subsystemHandle, 'BlockType');
catch
    error('extractAttributesCore:NoSelection', ...
        'The selected subsystem handle is no longer valid.');
end

if ~strcmp(blockType, 'SubSystem')
    error('extractAttributesCore:NotSubsystem', ...
        'The selected block is not a subsystem: %s', getfullname(subsystemHandle));
end

result.Subsystem = getfullname(subsystemHandle);

searchFolder = char(searchFolder);
outputFile = char(outputFile);

if ~isfolder(searchFolder)
    error('extractAttributesCore:InvalidSearchFolder', ...
        'The search folder does not exist: %s', searchFolder);
end

[outputFolder, ~, outputExtension] = fileparts(outputFile);
if ~strcmpi(outputExtension, '.m')
    error('extractAttributesCore:InvalidOutputFile', ...
        'The destination file must end with .m: %s', outputFile);
end
if isempty(outputFolder)
    outputFile = fullfile(pwd, outputFile);
    outputFolder = pwd;
end
if ~isfolder(outputFolder)
    error('extractAttributesCore:InvalidOutputFolder', ...
        'The destination folder does not exist: %s', outputFolder);
end
result.OutputFile = outputFile;

commonOptions = {'LookUnderMasks', 'on', 'FollowLinks', 'on', 'SearchDepth', 1};
inportHandles = find_system(subsystemHandle, commonOptions{:}, 'BlockType', 'Inport');
outportHandles = find_system(subsystemHandle, commonOptions{:}, 'BlockType', 'Outport');

inportNames = normalizeBlockNames(inportHandles);
outportNames = normalizeBlockNames(outportHandles);

switch options.PortChoice
    case 'Inports'
        tagNames = inportNames;
    case 'Outports'
        tagNames = outportNames;
    otherwise
        tagNames = [inportNames(:); outportNames(:)].';
        tagNames = unique(tagNames, 'stable');
end

if isempty(tagNames)
    error('extractAttributesCore:NoPorts', ...
        'No immediate %s were found in: %s', lower(options.PortChoice), result.Subsystem);
end

result.SearchTagCount = numel(tagNames);
result.Tags = struct('Name', tagNames(:), 'Count', num2cell(zeros(numel(tagNames), 1)));

tagLookup = containers.Map('KeyType', 'char', 'ValueType', 'logical');
for index = 1:numel(tagNames)
    key = strtrim(tagNames{index});
    if options.CaseInsensitive, key = lower(key); end
    if ~isempty(key), tagLookup(key) = true; end
end

matlabFiles = dir(fullfile(searchFolder, '**', '*.m'));
matlabFiles = matlabFiles(~[matlabFiles.isdir]);

keepFile = true(size(matlabFiles));
for index = 1:numel(matlabFiles)
    candidate = fullfile(matlabFiles(index).folder, matlabFiles(index).name);
    if strcmpi(candidate, outputFile)
        keepFile(index) = false;
    end
end
matlabFiles = matlabFiles(keepFile);
result.FilesFound = numel(matlabFiles);

recordMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
recordOrder = {};
filesRead = 0;

for fileIndex = 1:numel(matlabFiles)
    if cancelFcn()
        result.Cancelled = true;
        return;
    end

    progressFcn(fileIndex / max(1, numel(matlabFiles)), ...
        sprintf('Reading file %d of %d...', fileIndex, numel(matlabFiles)));

    sourceFile = fullfile(matlabFiles(fileIndex).folder, matlabFiles(fileIndex).name);
    % HIGH-SEVERITY FIX: Explicit UTF-8 file reading
    inputId = fopen(sourceFile, 'rt', 'n', 'UTF-8');
    if inputId == -1
        warning('extractAttributesCore:FileOpenFailed', 'Could not read: %s', sourceFile);
        continue;
    end

    filesRead = filesRead + 1;
    inputCleanup = onCleanup(@() fclose(inputId));
    lineNumber = 0;

    while true
        rawLine = fgetl(inputId);
        if ~ischar(rawLine), break; end

        lineNumber = lineNumber + 1;
        record = strtrim(rawLine);
        if isempty(record) || startsWith(record, '%'), continue; end

        dotPosition = find(record == '.', 1, 'first');
        if isempty(dotPosition) || dotPosition == 1, continue; end

        tag = strtrim(record(1:dotPosition - 1));
        if isempty(tag), continue; end

        if options.CaseInsensitive
            lookupTag = lower(tag);
            duplicateKey = lower(record);
        else
            lookupTag = tag;
            duplicateKey = record;
        end

        if ~isKey(tagLookup, lookupTag), continue; end

        relativeSource = makeRelativePath(sourceFile, searchFolder);
        source = sprintf('%s (line %d)', relativeSource, lineNumber);

        if ~isKey(recordMap, duplicateKey)
            recordMap(duplicateKey) = struct( ...
                'Record',   record, ...
                'Sources',  {{source}}, ...
                'TagIndex', findTagIndex(tag, tagNames, options.CaseInsensitive));
            recordOrder{end + 1} = duplicateKey; %#ok<AGROW>
        else
            item = recordMap(duplicateKey);
            if ~any(strcmp(item.Sources, source))
                item.Sources{end + 1} = source; %#ok<AGROW>
                recordMap(duplicateKey) = item;
            end
        end
    end
    clear inputCleanup;
end

result.FilesRead = filesRead;
result.FilesSkipped = result.FilesFound - filesRead;

for recordIndex = 1:numel(recordOrder)
    item = recordMap(recordOrder{recordIndex});
    if item.TagIndex >= 1 && item.TagIndex <= numel(result.Tags)
        result.Tags(item.TagIndex).Count = result.Tags(item.TagIndex).Count + 1;
    end
end

for tagIndex = 1:numel(result.Tags)
    if result.Tags(tagIndex).Count == 0
        result.Warnings{end + 1} = sprintf( ...
            'Tag "%s" matched 0 records.', result.Tags(tagIndex).Name);
    end
end

result.UniqueMatches = numel(recordOrder);

progressFcn(1, 'Writing output file...');
% HIGH-SEVERITY FIX: Explicit UTF-8 file writing
outputId = fopen(outputFile, 'wt', 'n', 'UTF-8');
if outputId == -1
    error('extractAttributesCore:OutputOpenFailed', 'Could not create: %s', outputFile);
end
outputCleanup = onCleanup(@() fclose(outputId));

if options.IncludeMetadata
    fprintf(outputId, '%% Auto-generated by extractAttributesCore\n');
    fprintf(outputId, '%% Generated on: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    fprintf(outputId, '%% Subsystem: %s\n', result.Subsystem);
    fprintf(outputId, '%% Search directory: %s\n\n', searchFolder);
end

for recordIndex = 1:numel(recordOrder)
    item = recordMap(recordOrder{recordIndex});
    if options.IncludeSourceComments
        for sourceIndex = 1:numel(item.Sources)
            fprintf(outputId, '%%   %s\n', item.Sources{sourceIndex});
        end
    end
    fprintf(outputId, '%s\n', item.Record);
    if options.IncludeSourceComments
        fprintf(outputId, '\n');
    end
end
clear outputCleanup;
end

function index = findTagIndex(tag, tagNames, caseInsensitive)
index = 0;
if caseInsensitive, matches = strcmpi(tagNames, tag); else, matches = strcmp(tagNames, tag); end
if any(matches), index = find(matches, 1, 'first'); end
end

function names = normalizeBlockNames(blockHandles)
if isempty(blockHandles), names = {}; return; end
names = get_param(blockHandles, 'Name');
if ischar(names), names = {names}; end
names = cellfun(@strtrim, names, 'UniformOutput', false);
names = names(~cellfun('isempty', names));
names = unique(names, 'stable');
names = names(:).';
end

function relativePath = makeRelativePath(fullPath, rootFolder)
rootWithSeparator = [char(rootFolder) filesep];
if strncmpi(fullPath, rootWithSeparator, numel(rootWithSeparator))
    relativePath = fullPath(numel(rootWithSeparator) + 1:end);
else
    relativePath = fullPath;
end
end

function options = fillDefaults(options, defaults)
if isempty(options), options = struct(); end
fields = fieldnames(defaults);
for index = 1:numel(fields)
    if ~isfield(options, fields{index})
        options.(fields{index}) = defaults.(fields{index});
    end
end
end