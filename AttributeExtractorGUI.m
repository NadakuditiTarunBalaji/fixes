function varargout = AttributeExtractorGUI(varargin)
%ATTRIBUTEEXTRACTORGUI GUI & Command-Line tool for extracting MATLAB attribute records.
%
% =========================================================================
% GUI USAGE:
%   AttributeExtractorGUI
%
% =========================================================================
% COMMAND LINE USAGE:
%   AttributeExtractorGUI(subsystem, searchFolder, outputFile)
%   AttributeExtractorGUI(subsystem, searchFolder, outputFile, 'Param', Value, ...)
%   result = AttributeExtractorGUI(...)
%
% INPUT ARGUMENTS:
%   subsystem       : (Optional) Subsystem name, path, or handle. 
%                     Use gcb, gcbh, or '' to use the currently selected block.
%   searchFolder    : Parent folder path containing the source .m files.
%   outputFile      : Destination .m file path.
%
% OPTIONAL NAME-VALUE ARGUMENTS:
%   'PortChoice'        : 'Both' (default) | 'Inports' | 'Outports'
%   'InformationChoice' : 'Both' (default) | 'Source comments' | 'Metadata only'
%   'CaseInsensitive'   : true (default) | false
%   'Verbose'           : true (default) | false (prints CLI summary)
% =========================================================================

    % Mode 1: GUI Mode (No input arguments)
    if nargin == 0
        launchGUI();
        return;
    end

    % Mode 2: Command Line Mode
    result = runCLI(varargin{:});
    if nargout > 0
        varargout{1} = result;
    end
end

%% ========================================================================
%% COMMAND-LINE EXECUTION LOGIC
%% ========================================================================
function result = runCLI(varargin)
    p = inputParser;
    p.FunctionName = 'AttributeExtractorGUI';

    addRequired(p, 'Subsystem', @(x) isempty(x) || ischar(x) || isstring(x) || (isnumeric(x) && isscalar(x)));
    addRequired(p, 'SearchFolder', @(x) ischar(x) || isstring(x));
    addRequired(p, 'OutputFile', @(x) ischar(x) || isstring(x));

    addParameter(p, 'PortChoice', 'Both', @(x) any(validatestring(x, {'Inports', 'Outports', 'Both'})));
    addParameter(p, 'InformationChoice', 'Both', @(x) any(validatestring(x, {'Source comments', 'Metadata only', 'Both'})));
    addParameter(p, 'CaseInsensitive', true, @(x) islogical(x) || isnumeric(x));
    addParameter(p, 'Verbose', true, @(x) islogical(x) || isnumeric(x));

    parse(p, varargin{:});
    args = p.Results;

    % 1. Resolve Subsystem
    if isempty(args.Subsystem)
        subsysHandle = validateSelectedSubsystem();
    else
        try
            subsysHandle = get_param(args.Subsystem, 'Handle');
        catch
            error('AttributeExtractorGUI:InvalidSubsystem', ...
                'Could not find or access the specified subsystem: %s', string(args.Subsystem));
        end
        if ~strcmp(get_param(subsysHandle, 'BlockType'), 'SubSystem')
            error('AttributeExtractorGUI:NotSubsystem', ...
                'The specified block is not a subsystem: %s', getfullname(subsysHandle));
        end
    end

    % 2. Validate Search Folder
    searchFolder = char(args.SearchFolder);
    if ~isfolder(searchFolder)
        error('AttributeExtractorGUI:InvalidSearchFolder', ...
            'The search folder does not exist: %s', searchFolder);
    end

    % 3. Validate Output File
    outputFile = char(args.OutputFile);
    [outFolder, ~, outExt] = fileparts(outputFile);
    if isempty(outExt) || ~strcmpi(outExt, '.m')
        outputFile = [outputFile '.m'];
        [outFolder, ~, ~] = fileparts(outputFile);
    end
    if isempty(outFolder)
        outputFile = fullfile(pwd, outputFile);
    elseif ~isfolder(outFolder)
        mkdir(outFolder);
    end

    % 4. Port Names
    [inportNames, outportNames] = getImmediatePortNames(subsysHandle);
    switch args.PortChoice
        case 'Inports'
            searchTags = inportNames;
        case 'Outports'
            searchTags = outportNames;
        otherwise
            searchTags = unique([inportNames(:); outportNames(:)], 'stable');
            searchTags = searchTags(:).';
    end

    if isempty(searchTags)
        error('AttributeExtractorGUI:NoSelectedPorts', ...
            'No immediate %s found in the subsystem "%s".', lower(args.PortChoice), getfullname(subsysHandle));
    end

    options = struct( ...
        'PortChoice', char(args.PortChoice), ...
        'InformationChoice', char(args.InformationChoice), ...
        'IncludeMetadata', any(strcmp(args.InformationChoice, {'Metadata only', 'Both'})), ...
        'IncludeSourceComments', any(strcmp(args.InformationChoice, {'Source comments', 'Both'})), ...
        'CaseInsensitive', logical(args.CaseInsensitive), ...
        'InportNames', {inportNames}, ...
        'OutportNames', {outportNames});

    if args.Verbose
        fprintf('\n--- Attribute Extraction Started ---\n');
        fprintf('Subsystem:     %s\n', getfullname(subsysHandle));
        fprintf('Search Folder: %s\n', searchFolder);
        fprintf('Output File:   %s\n', outputFile);
        fprintf('Port Filter:   %s (%d tags)\n', options.PortChoice, numel(searchTags));
    end

    % Run Extraction
    result = extractRecords(subsysHandle, searchTags, searchFolder, outputFile, options, []);

    if args.Verbose
        fprintf('Files Scanned: %d\n', result.FilesScanned);
        fprintf('Records Found: %d\n', result.UniqueMatches);
        fprintf('Status:        Success!\n');
        fprintf('------------------------------------\n\n');
    end
end

%% ========================================================================
%% CORE EXTRACTION & GENERATION ENGINE
%% ========================================================================
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

            % Filter out any existing declarations found inside search scripts
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

    % 2. Classify tags into inports vs outports
    inportSet = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    for idx = 1:numel(options.InportNames)
        inportSet(options.InportNames{idx}) = true;
    end

    % 3. Write Inports Section
    if any(strcmp(options.PortChoice, {'Inports', 'Both'}))
        inportTags = searchTags(cellfun(@(t) isKey(inportSet, t), searchTags));
        if ~isempty(inportTags)
            fprintf(outputId, '%% ===================== Inports =====================\n\n');
            writePortBlocks(outputId, inportTags, recordMap, recordOrder, options);
        end
    end

    % 4. Write Outports Section
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

        % Write the signal declaration first
        fprintf(outputId, '%s = Simulink.Signal;\n', cleanVarName);

        % Interleave matches directly under the declaration
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
                if options.IncludeSourceComments
                    fprintf(outputId, '\n');
                end
            end
        end

        % Blank line separating port blocks
        fprintf(outputId, '\n');
    end
end

%% ========================================================================
%% CHECK IF A LINE IS A SIMULINK.SIGNAL INSTANTIATION
%% ========================================================================
function tf = isSignalInstantiation(record, tag)
    tf = false;
    remainder = strtrim(record(length(tag) + 1:end));
    if ~isempty(regexp(remainder, '^=\s*Simulink\.Signal\s*;', 'once'))
        tf = true;
    end
end

%% ========================================================================
%% GUI LAUNCH LOGIC
%% ========================================================================
function launchGUI()
    state = struct('SearchFolder', '', 'OutputFile', '', 'LastResults', []);

    app = uifigure( ...
        'Name', 'Simulink Attribute Extractor', ...
        'Position', centerPosition(680, 570), ...
        'Resize', 'off');

    mainGrid = uigridlayout(app, [10 3]);
    mainGrid.RowHeight = {52, 32, 62, 32, 62, 32, 32, 42, '1x', 34};
    mainGrid.ColumnWidth = {155, '1x', 120};
    mainGrid.Padding = [18 16 18 14];
    mainGrid.RowSpacing = 8;
    mainGrid.ColumnSpacing = 8;

    titleLabel = uilabel(mainGrid, ...
        'Text', 'Simulink Attribute Extractor', ...
        'FontSize', 20, ...
        'FontWeight', 'bold');
    titleLabel.Layout.Row = 1;
    titleLabel.Layout.Column = [1 3];

    subsystemCaption = uilabel(mainGrid, ...
        'Text', 'Selected subsystem:', ...
        'FontWeight', 'bold');
    subsystemCaption.Layout.Row = 2;
    subsystemCaption.Layout.Column = 1;

    subsystemLabel = uilabel(mainGrid, ...
        'Text', getSelectedSubsystemText(), ...
        'Tooltip', 'Subsystem currently selected in Simulink');
    subsystemLabel.Layout.Row = 2;
    subsystemLabel.Layout.Column = 2;

    refreshButton = uibutton(mainGrid, 'push', ...
        'Text', 'Refresh Selection', ...
        'ButtonPushedFcn', @refreshSelection);
    refreshButton.Layout.Row = 2;
    refreshButton.Layout.Column = 3;

    portPanel = uipanel(mainGrid, ...
        'Title', 'Ports to use as search tags', ...
        'FontWeight', 'bold');
    portPanel.Layout.Row = 3;
    portPanel.Layout.Column = [1 3];

    portGroup = uibuttongroup(portPanel, ...
        'Position', [12 4 620 30], ...
        'BorderType', 'none');
    uiradiobutton(portGroup, 'Text', 'Inports', 'Position', [8 5 100 22]);
    uiradiobutton(portGroup, 'Text', 'Outports', 'Position', [145 5 100 22]);
    bothPortsButton = uiradiobutton(portGroup, 'Text', 'Both', 'Position', [290 5 100 22]);
    portGroup.SelectedObject = bothPortsButton;

    searchCaption = uilabel(mainGrid, ...
        'Text', 'Search directory:', ...
        'FontWeight', 'bold');
    searchCaption.Layout.Row = 4;
    searchCaption.Layout.Column = 1;

    searchEdit = uieditfield(mainGrid, 'text', ...
        'Placeholder', 'Select the parent folder containing .m files');
    searchEdit.Layout.Row = 4;
    searchEdit.Layout.Column = 2;

    browseSearchButton = uibutton(mainGrid, 'push', ...
        'Text', 'Browse...', ...
        'ButtonPushedFcn', @browseSearchFolder);
    browseSearchButton.Layout.Row = 4;
    browseSearchButton.Layout.Column = 3;

    outputPanel = uipanel(mainGrid, ...
        'Title', 'Information written to the generated file', ...
        'FontWeight', 'bold');
    outputPanel.Layout.Row = 5;
    outputPanel.Layout.Column = [1 3];

    outputGroup = uibuttongroup(outputPanel, ...
        'Position', [12 4 620 30], ...
        'BorderType', 'none');
    uiradiobutton(outputGroup, 'Text', 'Source comments', 'Position', [8 5 130 22], ...
        'Tooltip', 'Add source file and line comments above each record');
    uiradiobutton(outputGroup, 'Text', 'Metadata only', 'Position', [185 5 130 22], ...
        'Tooltip', 'Add only the generated-file summary header');
    bothInfoButton = uiradiobutton(outputGroup, 'Text', 'Both', 'Position', [365 5 100 22], ...
        'Tooltip', 'Add the metadata header and source comments');
    outputGroup.SelectedObject = bothInfoButton;

    destinationCaption = uilabel(mainGrid, ...
        'Text', 'Destination file:', ...
        'FontWeight', 'bold');
    destinationCaption.Layout.Row = 6;
    destinationCaption.Layout.Column = 1;

    destinationEdit = uieditfield(mainGrid, 'text', ...
        'Placeholder', 'Choose destination folder and .m filename');
    destinationEdit.Layout.Row = 6;
    destinationEdit.Layout.Column = 2;

    browseOutputButton = uibutton(mainGrid, 'push', ...
        'Text', 'Browse...', ...
        'ButtonPushedFcn', @browseOutputFile);
    browseOutputButton.Layout.Row = 6;
    browseOutputButton.Layout.Column = 3;

    caseCheck = uicheckbox(mainGrid, ...
        'Text', 'Case-insensitive tag matching', ...
        'Value', true);
    caseCheck.Layout.Row = 7;
    caseCheck.Layout.Column = [1 2];

    extractButton = uibutton(mainGrid, 'push', ...
        'Text', 'Extract Attributes', ...
        'FontWeight', 'bold', ...
        'ButtonPushedFcn', @runExtraction);
    extractButton.Layout.Row = 8;
    extractButton.Layout.Column = [2 3];

    logArea = uitextarea(mainGrid, ...
        'Editable', 'off', ...
        'Value', {'Ready. Select a Simulink subsystem and configure the extraction.'});
    logArea.Layout.Row = 9;
    logArea.Layout.Column = [1 3];

    closeButton = uibutton(mainGrid, 'push', ...
        'Text', 'Close', ...
        'ButtonPushedFcn', @(~, ~) delete(app));
    closeButton.Layout.Row = 10;
    closeButton.Layout.Column = 3;

    function refreshSelection(~, ~)
        subsystemLabel.Text = getSelectedSubsystemText();
        appendLog(['Selection: ' subsystemLabel.Text]);
    end

    function browseSearchFolder(~, ~)
        startFolder = pwd;
        if isfolder(strtrim(searchEdit.Value))
            startFolder = strtrim(searchEdit.Value);
        end
        chosenFolder = uigetdir(startFolder, 'Select parent directory containing MATLAB files');
        if isequal(chosenFolder, 0)
            return;
        end
        state.SearchFolder = chosenFolder;
        searchEdit.Value = chosenFolder;
        appendLog(['Search directory: ' chosenFolder]);
    end

    function browseOutputFile(~, ~)
        initialFile = fullfile(pwd, 'ExtractedAttributes.m');
        if isfolder(strtrim(searchEdit.Value))
            initialFile = fullfile(strtrim(searchEdit.Value), 'ExtractedAttributes.m');
        end
        [name, folder] = uiputfile({'*.m', 'MATLAB files (*.m)'}, 'Select destination MATLAB file', initialFile);
        if isequal(name, 0) || isequal(folder, 0)
            return;
        end
        [~, baseName, extension] = fileparts(name);
        if isempty(extension)
            name = [baseName '.m'];
        elseif ~strcmpi(extension, '.m')
            uialert(app, 'The destination must be a .m file.', 'Invalid Destination', 'Icon', 'error');
            return;
        end
        state.OutputFile = fullfile(folder, name);
        destinationEdit.Value = state.OutputFile;
        appendLog(['Destination: ' state.OutputFile]);
    end

    function runExtraction(~, ~)
        extractButton.Enable = 'off';
        cleanupButton = onCleanup(@() set(extractButton, 'Enable', 'on'));

        try
            selectedHandle = validateSelectedSubsystem();
            subsystemLabel.Text = getfullname(selectedHandle);

            searchFolder = strtrim(searchEdit.Value);
            if ~isfolder(searchFolder)
                error('AttributeExtractorGUI:InvalidSearchFolder', 'Select a valid parent search directory.');
            end

            outputFile = strtrim(destinationEdit.Value);
            [outputFolder, ~, outputExtension] = fileparts(outputFile);
            if isempty(outputFile) || ~strcmpi(outputExtension, '.m')
                error('AttributeExtractorGUI:InvalidOutputFile', 'Select a valid destination .m file.');
            end
            if isempty(outputFolder)
                outputFile = fullfile(pwd, outputFile);
                outputFolder = pwd;
            end
            if ~isfolder(outputFolder)
                error('AttributeExtractorGUI:InvalidOutputFolder', 'The selected destination folder does not exist.');
            end

            portChoice = portGroup.SelectedObject.Text;
            informationChoice = outputGroup.SelectedObject.Text;
            [inportNames, outportNames] = getImmediatePortNames(selectedHandle);

            switch portChoice
                case 'Inports'
                    searchTags = inportNames;
                case 'Outports'
                    searchTags = outportNames;
                otherwise
                    searchTags = unique([inportNames(:); outportNames(:)], 'stable');
                    searchTags = searchTags(:).';
            end

            if isempty(searchTags)
                error('AttributeExtractorGUI:NoSelectedPorts', ...
                    'No immediate %s were found in the selected subsystem.', lower(portChoice));
            end

            progress = uiprogressdlg(app, ...
                'Title', 'Extracting attributes', ...
                'Message', 'Finding MATLAB files...', ...
                'Indeterminate', 'on', ...
                'Cancelable', 'on');
            progressCleanup = onCleanup(@() safeClose(progress));

            options = struct( ...
                'PortChoice', portChoice, ...
                'InformationChoice', informationChoice, ...
                'IncludeMetadata', any(strcmp(informationChoice, {'Metadata only', 'Both'})), ...
                'IncludeSourceComments', any(strcmp(informationChoice, {'Source comments', 'Both'})), ...
                'CaseInsensitive', caseCheck.Value, ...
                'InportNames', {inportNames}, ...
                'OutportNames', {outportNames});

            state.LastResults = extractRecords(selectedHandle, searchTags, searchFolder, outputFile, options, progress);

            clear progressCleanup;
            safeClose(progress);

            result = state.LastResults;
            appendLog(sprintf('Completed: %d files scanned, %d unique records written.', ...
                result.FilesScanned, result.UniqueMatches));
            appendLog(['Output: ' result.OutputFile]);

            uialert(app, sprintf([ ...
                'Extraction completed.\n\n', ...
                'Port selection: %s\n', ...
                'Search tags: %d\n', ...
                'Files scanned: %d\n', ...
                'Unique records: %d\n\n', ...
                'Output:\n%s'], ...
                result.PortChoice, result.SearchTagCount, ...
                result.FilesScanned, result.UniqueMatches, ...
                result.OutputFile), ...
                'Extraction Complete', 'Icon', 'success');

        catch exception
            appendLog(['ERROR: ' exception.message]);
            uialert(app, exception.message, 'Extraction Failed', 'Icon', 'error');
        end
        clear cleanupButton;
    end

    function appendLog(message)
        timestamp = datestr(now, 'HH:MM:SS');
        existing = logArea.Value;
        if ischar(existing)
            existing = {existing};
        end
        logArea.Value = [existing; {[timestamp '  ' message]}];
        drawnow limitrate;
    end
end

%% ========================================================================
%% HELPER FUNCTIONS
%% ========================================================================
function [inportNames, outportNames] = getImmediatePortNames(subsystemHandle)
    commonOptions = {'LookUnderMasks', 'on', 'FollowLinks', 'on', 'SearchDepth', 1};
    inportHandles = find_system(subsystemHandle, commonOptions{:}, 'BlockType', 'Inport');
    outportHandles = find_system(subsystemHandle, commonOptions{:}, 'BlockType', 'Outport');
    inportNames = normalizeBlockNames(inportHandles);
    outportNames = normalizeBlockNames(outportHandles);
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

function selectedHandle = validateSelectedSubsystem()
    selectedHandle = gcbh;
    if isempty(selectedHandle) || selectedHandle == -1
        error('AttributeExtractorGUI:NoSelection', ...
            'No Simulink block is selected. Open the model and select the required subsystem.');
    end
    if ~strcmp(get_param(selectedHandle, 'BlockType'), 'SubSystem')
        error('AttributeExtractorGUI:NotSubsystem', ...
            'The selected block is not a subsystem: %s', getfullname(selectedHandle));
    end
end

function text = getSelectedSubsystemText()
    try
        selectedHandle = gcbh;
        if isempty(selectedHandle) || selectedHandle == -1
            text = '<No subsystem selected>';
        elseif strcmp(get_param(selectedHandle, 'BlockType'), 'SubSystem')
            text = getfullname(selectedHandle);
        else
            text = ['<Selected block is not a subsystem: ' getfullname(selectedHandle) '>'];
        end
    catch
        text = '<No subsystem selected>';
    end
end

function writeMetadataNames(fileId, heading, names)
    fprintf(fileId, '%% %s:\n', heading);
    if isempty(names)
        fprintf(fileId, '%%   <none>\n\n');
        return;
    end
    for index = 1:numel(names)
        fprintf(fileId, '%%   %s\n', names{index});
    end
    fprintf(fileId, '\n');
end

function relativePath = makeRelativePath(fullPath, rootFolder)
    rootWithSeparator = [char(rootFolder) filesep];
    if strncmpi(fullPath, rootWithSeparator, numel(rootWithSeparator))
        relativePath = fullPath(numel(rootWithSeparator) + 1:end);
    else
        relativePath = fullPath;
    end
end

function position = centerPosition(width, height)
    screen = get(groot, 'ScreenSize');
    left = max(1, round((screen(3) - width) / 2));
    bottom = max(1, round((screen(4) - height) / 2));
    position = [left bottom width height];
end

function safeClose(dialogHandle)
    if ~isempty(dialogHandle) && isvalid(dialogHandle)
        close(dialogHandle);
    end
end