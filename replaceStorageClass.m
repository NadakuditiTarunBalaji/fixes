function results = replaceStorageClass(selectedStorageClass, dataFilePath, overwriteBackup)
%REPLACESTORAGECLASS Replace StorageClass values in *_data.m files.
%
%   replaceStorageClass('Auto')
%   replaceStorageClass('ExportedGlobal')
%   replaceStorageClass('ImportedExtern')
%   result = replaceStorageClass('Auto', filePath, false)
%
% The function searches all *_data.m files in the current folder and
% replaces existing StorageClass values:
%   'Auto'
%   'ExportedGlobal'
%   'ImportedExtern'
%
% A .bak backup file is created before modifying each file.

    if nargin < 2 || isempty(dataFilePath)
        dataFilePath = '';
    end
    if nargin < 3 || isempty(overwriteBackup)
        overwriteBackup = false;
    end

    % Valid StorageClass options
    validOptions = {'Auto', 'ExportedGlobal', 'ImportedExtern'};

    % Check input
    if nargin < 1
        error(['Please specify a StorageClass. Example: ', ...
               'replaceStorageClass(''Auto'')']);
    end

    if ~ischar(selectedStorageClass) && ~isstring(selectedStorageClass)
        error('StorageClass must be a character vector or string.');
    end

    selectedStorageClass = char(selectedStorageClass);

    if ~ismember(selectedStorageClass, validOptions)
        error(['Invalid StorageClass. Valid options are: ', ...
               'Auto, ExportedGlobal, ImportedExtern']);
    end

    % Use an explicit file for the application, or retain folder mode for
    % existing standalone callers.
    if isempty(dataFilePath)
        files = dir(fullfile(pwd, '*_data.m'));
    else
        dataFilePath = char(dataFilePath);
        if ~isfile(dataFilePath)
            error('replaceStorageClass:MissingFile', ...
                'Data file does not exist: %s', dataFilePath);
        end
        files = dir(dataFilePath);
    end

    results = repmat(struct( ...
        'FilePath', '', ...
        'Changed', false, ...
        'ReplacementCount', 0, ...
        'Warnings', {{}}, ...
        'BackupPath', ''), 1, numel(files));

    if isempty(files)
        fprintf('No *_data.m files found in:\n%s\n', pwd);
        return;
    end

    fprintf('\nSelected StorageClass: %s\n', selectedStorageClass);
    fprintf('Searching %d file(s)...\n\n', numel(files));

    % Search and replace
    for k = 1:numel(files)

        fileName = files(k).name;
        filePath = fullfile(files(k).folder, fileName);
        results(k).FilePath = filePath;

        % Read file
        fileText = fileread(filePath);

        % Search for StorageClass
        pattern = ['\.StorageClass\s*=\s*''', ...
                   '(?:Auto|ExportedGlobal|ImportedExtern)', ...
                   ''''];

        % Check whether a match exists
        if isempty(regexp(fileText, pattern, 'once'))
            declarations = regexp(fileText, ...
                '(?m)^[ \t]*([A-Za-z]\w*)[ \t]*=[ \t]*Simulink\.(Signal|Parameter)(?:[ \t]*;|[ \t]*\()', ...
                'tokens');
            if ~isempty(declarations)
                warning('replaceStorageClass:MissingAssignment', ...
                    'No StorageClass assignment found in %s; declared objects were left unchanged.', ...
                    filePath);
                results(k).Warnings{end + 1} = ...
                    sprintf('No StorageClass assignment found; declared objects were left unchanged.');
            else
                warning('replaceStorageClass:NoStorageClassAssignments', ...
                    'Failed to convert %s: no StorageClass assignments found.', filePath);
                results(k).Warnings{end + 1} = ...
                    'Failed to convert: no StorageClass assignments found.';
            end
            fprintf('No match: %s\n', fileName);
            continue;
        end

        declarations = regexp(fileText, ...
            '(?m)^[ \t]*([A-Za-z]\w*)[ \t]*=[ \t]*Simulink\.(Signal|Parameter)(?:[ \t]*;|[ \t]*\()', ...
            'tokens');
        assignedTokens = regexp(fileText, ...
            '(?m)^[ \t]*([A-Za-z]\w*)(?:\.CoderInfo)?\.StorageClass[ \t]*=[ \t]*''(?:Auto|ExportedGlobal|ImportedExtern)''', ...
            'tokens');
        declaredNames = cellfun(@(token) token{1}, declarations, ...
            'UniformOutput', false);
        assignedNames = cellfun(@(token) token{1}, assignedTokens, ...
            'UniformOutput', false);
        missingNames = setdiff(declaredNames, assignedNames, 'stable');
        if ~isempty(missingNames)
            missingMessage = sprintf( ...
                'No StorageClass assignment for: %s. These objects were left unchanged.', ...
                strjoin(missingNames, ', '));
            warning('replaceStorageClass:MissingAssignment', ...
                '%s', missingMessage);
            results(k).Warnings{end + 1} = missingMessage;
        end

        fprintf('Match found: %s\n', fileName);

        % Create backup
        backupPath = [filePath '.bak'];

        if ~isfile(backupPath)
            copyfile(filePath, backupPath);
            fprintf('  Backup created: %s\n', backupPath);
        elseif overwriteBackup
            copyfile(filePath, backupPath, 'f');
            fprintf('  Backup overwritten: %s\n', backupPath);
        else
            fprintf('  Backup already exists: %s\n', backupPath);
        end
        results(k).BackupPath = backupPath;

        % Replacement text
        replacement = ['.StorageClass = ''', ...
                       selectedStorageClass, ...
                       ''''];

        % Replace all occurrences
        fileText = regexprep(fileText, pattern, replacement);
        results(k).ReplacementCount = numel(regexp(fileText, ...
            ['\.StorageClass\s*=\s*''', selectedStorageClass, ''''], 'match'));

        % Write modified file
        fid = fopen(filePath, 'w');

        if fid == -1
            warning('Could not write file: %s', filePath);
            continue;
        end

        fwrite(fid, fileText, 'char');
        fclose(fid);
        results(k).Changed = true;

        fprintf('  Replaced with: .StorageClass = ''%s''\n', ...
                selectedStorageClass);
    end

    fprintf('\nDone.\n');
end