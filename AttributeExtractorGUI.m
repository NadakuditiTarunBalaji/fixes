function AttributeExtractorGUI
%ATTRIBUTEEXTRACTORGUI GUI for extracting unique MATLAB attribute records.
%
% Workflow:
%   1. Open a Simulink model and select a subsystem.
%   2. Run: AttributeExtractorGUI
%   3. Choose Inports, Outports, or Both.
%   4. Choose Source comments, Metadata, or Both.
%   5. Select the parent search directory and destination .m file.
%   6. Click Extract Attributes.
%
% Matching rule:
%   A port named "car" matches records beginning with "car.", such as:
%       car.speed
%       car.color
%
% Duplicate behavior:
%   An identical trimmed record is written only once. If source comments are
%   enabled, all files and line numbers containing that record are listed.

    state = struct( ...
        'SearchFolder', '', ...
        'OutputFile', '', ...
        'LastResults', []);

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
    uiradiobutton(portGroup, 'Text', 'Inports', ...
        'Position', [8 5 100 22]);
    uiradiobutton(portGroup, 'Text', 'Outports', ...
        'Position', [145 5 100 22]);
    bothPortsButton = uiradiobutton(portGroup, 'Text', 'Both', ...
        'Position', [290 5 100 22]);
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
    uiradiobutton(outputGroup, 'Text', 'Source comments', ...
        'Position', [8 5 130 22], ...
        'Tooltip', 'Add source file and line comments above each record');
    uiradiobutton(outputGroup, 'Text', 'Metadata only', ...
        'Position', [185 5 130 22], ...
        'Tooltip', 'Add only the generated-file summary header');
    bothInfoButton = uiradiobutton(outputGroup, 'Text', 'Both', ...
        'Position', [365 5 100 22], ...
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

        chosenFolder = uigetdir(startFolder, ...
            'Select parent directory containing MATLAB files');
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
            initialFile = fullfile(strtrim(searchEdit.Value), ...
                'ExtractedAttributes.m');
        end

        [name, folder] = uiputfile( ...
            {'*.m', 'MATLAB files (*.m)'}, ...
            'Select destination MATLAB file', initialFile);
        if isequal(name, 0) || isequal(folder, 0)
            return;
        end

        [~, baseName, extension] = fileparts(name);
        if isempty(extension)
            name = [baseName '.m'];
        elseif ~strcmpi(extension, '.m')
            uialert(app, 'The destination must be a .m file.', ...
                'Invalid Destination', 'Icon', 'error');
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
                error('AttributeExtractorGUI:InvalidSearchFolder', ...
                    'Select a valid parent search directory.');
            end

            outputFile = strtrim(destinationEdit.Value);
            [outputFolder, ~, outputExtension] = fileparts(outputFile);
            if isempty(outputFile) || ~strcmpi(outputExtension, '.m')
                error('AttributeExtractorGUI:InvalidOutputFile', ...
                    'Select a valid destination .m file.');
            end
            if isempty(outputFolder)
                outputFile = fullfile(pwd, outputFile);
                outputFolder = pwd;
            end
            if ~isfolder(outputFolder)
                error('AttributeExtractorGUI:InvalidOutputFolder', ...
                    'The selected destination folder does not exist.');
            end

            portChoice = portGroup.SelectedObject.Text;
            informationChoice = outputGroup.SelectedObject.Text;

            includeMetadata = any(strcmp(informationChoice, ...
                {'Metadata only', 'Both'}));
            includeSourceComments = any(strcmp(informationChoice, ...
                {'Source comments', 'Both'}));

            appendLog('Reading immediate subsystem ports...');
            drawnow;

            [inportNames, outportNames] = getImmediatePortNames(selectedHandle);

            switch portChoice
                case 'Inports'
                    searchTags = inportNames;
                case 'Outports'
                    searchTags = outportNames;
                otherwise
                    searchTags = unique( ...
                        [inportNames(:); outportNames(:)], 'stable');
                    searchTags = searchTags(:).';
            end

            if isempty(searchTags)
                error('AttributeExtractorGUI:NoSelectedPorts', ...
                    'No immediate %s were found in the selected subsystem.', ...
                    lower(portChoice));
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
                'IncludeMetadata', includeMetadata, ...
                'IncludeSourceComments', includeSourceComments, ...
                'CaseInsensitive', caseCheck.Value, ...
                'InportNames', {inportNames}, ...
                'OutportNames', {outportNames});

            state.LastResults = extractRecords( ...
                selectedHandle, searchTags, searchFolder, outputFile, ...
                options, progress);

            clear progressCleanup;
            safeClose(progress);

            result = state.LastResults;
            appendLog(sprintf(['Completed: %d files scanned, ', ...
                '%d unique records written.'], ...
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
            uialert(app, exception.message, 'Extraction Failed', ...
                'Icon', 'error');
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

function result = extractRecords(subsystemHandle, searchTags, ...
        searchFolder, outputFile, options, progress)
%EXTRACTRECORDS Scan .m files and generate the deduplicated output file.

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

    keepFile = true(size(matlabFiles));
    for index = 1:numel(matlabFiles)
        candidate = fullfile(matlabFiles(index).folder, ...
            matlabFiles(index).name);
        if strcmpi(candidate, outputFile)
            keepFile(index) = false;
        end
    end
    matlabFiles = matlabFiles(keepFile);

    tagLookup = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    for index = 1:numel(searchTags)
        key = strtrim(searchTags{index});
        if options.CaseInsensitive
            key = lower(key);
        end
        tagLookup(key) = true;
    end

    recordMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
    recordOrder = {};
    filesRead = 0;

    progress.Indeterminate = 'off';

    for fileIndex = 1:numel(matlabFiles)
        if progress.CancelRequested
            result.Cancelled = true;
            error('AttributeExtractorGUI:Cancelled', ...
                'Extraction was cancelled by the user.');
        end

        progress.Value = fileIndex / max(1, numel(matlabFiles));
        progress.Message = sprintf('Reading file %d of %d...', ...
            fileIndex, numel(matlabFiles));
        drawnow limitrate;

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

            relativeSource = makeRelativePath(sourceFile, searchFolder);
            source = sprintf('%s (line %d)', relativeSource, lineNumber);

            if ~isKey(recordMap, duplicateKey)
                recordMap(duplicateKey) = struct( ...
                    'Record', record, 'Sources', {{source}});
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

    progress.Message = 'Writing output file...';
    drawnow;

    outputId = fopen(outputFile, 'wt');
    if outputId == -1
        error('AttributeExtractorGUI:OutputOpenFailed', ...
            'Could not create the destination file: %s', outputFile);
    end
    outputCleanup = onCleanup(@() fclose(outputId));

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
        fprintf(outputId, '%% Unique matching records: %d\n\n', ...
            numel(recordOrder));

        if any(strcmp(options.PortChoice, {'Inports', 'Both'}))
            writeMetadataNames(outputId, 'Inport tags', options.InportNames);
        end
        if any(strcmp(options.PortChoice, {'Outports', 'Both'}))
            writeMetadataNames(outputId, 'Outport tags', options.OutportNames);
        end
    end

    % --- NEW: Write Simulink.Signal Declarations for unique Port names ---
    fprintf(outputId, '%% =========================================================================\n');
    fprintf(outputId, '%% Simulink Signal Declarations\n');
    fprintf(outputId, '%% =========================================================================\n');
    
    if any(strcmp(options.PortChoice, {'Inports', 'Both'})) && ~isempty(options.InportNames)
        fprintf(outputId, '%% Inport Signals\n');
        for pIdx = 1:numel(options.InportNames)
            % Clean up name to be a valid MATLAB variable name
            cleanVarName = matlab.lang.makeValidName(options.InportNames{pIdx});
            fprintf(outputId, '%s = Simulink.Signal;\n', cleanVarName);
        end
        fprintf(outputId, '\n');
    end
    
    if any(strcmp(options.PortChoice, {'Outports', 'Both'})) && ~isempty(options.OutportNames)
        fprintf(outputId, '%% Outport Signals\n');
        for pIdx = 1:numel(options.OutportNames)
            % Clean up name to be a valid MATLAB variable name
            cleanVarName = matlab.lang.makeValidName(options.OutportNames{pIdx});
            fprintf(outputId, '%s = Simulink.Signal;\n', cleanVarName);
        end
        fprintf(outputId, '\n');
    end
    fprintf(outputId, '%% =========================================================================\n\n');
    % ---------------------------------------------------------------------

    for recordIndex = 1:numel(recordOrder)
        item = recordMap(recordOrder{recordIndex});

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

    clear outputCleanup;

    result.FilesScanned = filesRead;
    result.UniqueMatches = numel(recordOrder);
end

function [inportNames, outportNames] = getImmediatePortNames(subsystemHandle)
%GETIMMEDIATEPORTNAMES Return immediate Inport and Outport block names.

    commonOptions = { ...
        'LookUnderMasks', 'on', ...
        'FollowLinks', 'on', ...
        'SearchDepth', 1};

    inportHandles = find_system(subsystemHandle, ...
        commonOptions{:}, 'BlockType', 'Inport');
    outportHandles = find_system(subsystemHandle, ...
        commonOptions{:}, 'BlockType', 'Outport');

    inportNames = normalizeBlockNames(inportHandles);
    outportNames = normalizeBlockNames(outportHandles);
end

function names = normalizeBlockNames(blockHandles)
%NORMALIZEBLOCKNAMES Get trimmed, unique block names as a row cell array.

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
%VALIDATESELECTEDSUBSYSTEM Return the selected subsystem handle.

    selectedHandle = gcbh;
    if isempty(selectedHandle) || selectedHandle == -1
        error('AttributeExtractorGUI:NoSelection', ...
            ['No Simulink block is selected. Open the model and select ', ...
             'the required subsystem.']);
    end

    if ~strcmp(get_param(selectedHandle, 'BlockType'), 'SubSystem')
        error('AttributeExtractorGUI:NotSubsystem', ...
            'The selected block is not a subsystem: %s', ...
            getfullname(selectedHandle));
    end
end

function text = getSelectedSubsystemText()
%GETSELECTEDSUBSYSTEMTEXT Return display text for the current selection.

    try
        selectedHandle = gcbh;
        if isempty(selectedHandle) || selectedHandle == -1
            text = '<No subsystem selected>';
        elseif strcmp(get_param(selectedHandle, 'BlockType'), 'SubSystem')
            text = getfullname(selectedHandle);
        else
            text = ['<Selected block is not a subsystem: ' ...
                getfullname(selectedHandle) '>'];
        end
    catch
        text = '<No subsystem selected>';
    end
end

function writeMetadataNames(fileId, heading, names)
%WRITEMETADATANAMES Write a metadata comment section.

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
%MAKERELATIVEPATH Return a path relative to the selected search folder.

    rootWithSeparator = [char(rootFolder) filesep];
    if strncmpi(fullPath, rootWithSeparator, numel(rootWithSeparator))
        relativePath = fullPath(numel(rootWithSeparator) + 1:end);
    else
        relativePath = fullPath;
    end
end

function position = centerPosition(width, height)
%CENTERPOSITION Return a screen-centered figure position.

    screen = get(groot, 'ScreenSize');
    left = max(1, round((screen(3) - width) / 2));
    bottom = max(1, round((screen(4) - height) / 2));
    position = [left bottom width height];
end

function safeClose(dialogHandle)
%SAFECLOSE Close a UI dialog if it is still valid.

    if ~isempty(dialogHandle) && isvalid(dialogHandle)
        close(dialogHandle);
    end
end