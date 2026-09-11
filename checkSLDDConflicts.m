function issues = checkSLDDConflicts(modelsFolder, progressFcn)
%CHECKSLDDCONFLICTS Scan every .sldd file under modelsFolder for
% Simulink.Signal/Simulink.Parameter symbols whose Min/Max differ
% between dictionaries.
%
%   issues = checkSLDDConflicts(modelsFolder)
%   issues = checkSLDDConflicts(modelsFolder, progressFcn)

if nargin < 2 || isempty(progressFcn)
    progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
end

issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
    'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

progressFcn(0, 'Scanning for .sldd files...');
slddFiles = dir(fullfile(modelsFolder, '**', '*.sldd'));
slddFiles = slddFiles(~[slddFiles.isdir]);

if isempty(slddFiles)
    issues(end + 1) = struct( ...
        'Category', 'Info', 'Severity', 'info', ...
        'Model', 'N/A', 'Port', '', ...
        'Description', ['No .sldd files found under the models folder. ' ...
            'SLDD conflict check skipped.'], ...
        'FixMethod', 'none', 'FixData', struct());
    progressFcn(1, 'No .sldd files found.');
    return;
end

allDefs = containers.Map('KeyType', 'char', 'ValueType', 'any');

for i = 1:numel(slddFiles)
    dictPath = fullfile(slddFiles(i).folder, slddFiles(i).name);
    dictName = slddFiles(i).name;
    progressFcn((i - 1) / numel(slddFiles), sprintf('Scanning dictionary: %s', dictName));

    dictObj = [];
    try
        dictObj = Simulink.data.dictionary.open(dictPath);
        dSect = getSection(dictObj, 'Design Data');
        entries = asEntryArray(find(dSect));

        for j = 1:numel(entries)
            try
                entryObj = entries(j);
                symName = entryObj.Name;
                symValue = getValue(entryObj);

                [hasMinMax, symMin, symMax] = extractMinMax(symValue);
                if hasMinMax
                    def = struct('DictPath', dictPath, 'DictName', dictName, ...
                        'Min', symMin, 'Max', symMax);
                    if isKey(allDefs, symName)
                        allDefs(symName) = [allDefs(symName); def];
                    else
                        allDefs(symName) = def;
                    end
                end
            catch
                % Skip entries that cannot be read.
            end
        end
        close(dictObj);
    catch dictErr
        if ~isempty(dictObj)
            try close(dictObj); catch, end
        end
        issues(end + 1) = struct( ... %#ok<AGROW>
            'Category', 'SLDD', 'Severity', 'warning', ...
            'Model', dictName, 'Port', '', ...
            'Description', sprintf('Could not scan dictionary "%s": %s', ...
                dictName, dictErr.message), ...
            'FixMethod', 'none', 'FixData', struct());
    end
end

symNames = keys(allDefs);
for i = 1:numel(symNames)
    symName = symNames{i};
    defs = allDefs(symName);
    if numel(defs) < 2
        continue;
    end

    minStrings = arrayfun(@(d) mat2str(d.Min), defs, 'UniformOutput', false);
    maxStrings = arrayfun(@(d) mat2str(d.Max), defs, 'UniformOutput', false);
    if numel(unique(minStrings)) <= 1 && numel(unique(maxStrings)) <= 1
        continue;   % every definition agrees
    end

    masterIdx = pickMasterDefinition(minStrings, maxStrings);
    dictNames = {defs.DictName};

    issues(end + 1) = struct( ... %#ok<AGROW>
        'Category', 'SLDD', ...
        'Severity', 'error', ...
        'Model', symName, ...
        'Port', '', ...
        'Description', sprintf(['Symbol "%s" has %d inconsistent ' ...
            'definition(s) across: %s. Master: %s (Min=%s, Max=%s)'], ...
            symName, numel(defs), strjoin(dictNames, ', '), ...
            defs(masterIdx).DictName, ...
            mat2str(defs(masterIdx).Min), mat2str(defs(masterIdx).Max)), ...
        'FixMethod', 'SyncToMaster', ...
        'FixData', struct( ...
            'Symbol', symName, ...
            'Definitions', defs, ...
            'MasterIndex', masterIdx));
end

progressFcn(1, sprintf('SLDD scan complete: %d dictionary(ies) checked.', ...
    numel(slddFiles)));
end

function [hasMinMax, symMin, symMax] = extractMinMax(symValue)
hasMinMax = false;
symMin = [];
symMax = [];
if isobject(symValue)
    if isprop(symValue, 'Min') && isprop(symValue, 'Max')
        symMin = symValue.Min;
        symMax = symValue.Max;
        hasMinMax = true;
    end
elseif isstruct(symValue)
    if isfield(symValue, 'Min') && isfield(symValue, 'Max')
        symMin = symValue.Min;
        symMax = symValue.Max;
        hasMinMax = true;
    end
end
end

function masterIdx = pickMasterDefinition(minStrings, maxStrings)
%PICKMASTERDEFINITION Choose the most common (Min,Max) pair as master
% (majority vote) instead of just the first non-empty one; ties favor
% the earliest definition.

combined = strcat(minStrings, '|', maxStrings);
uniqueCombos = unique(combined);
bestCount = -1;
bestCombo = combined{1};
for k = 1:numel(uniqueCombos)
    n = sum(strcmp(combined, uniqueCombos{k}));
    if n > bestCount
        bestCount = n;
        bestCombo = uniqueCombos{k};
    end
end
masterIdx = find(strcmp(combined, bestCombo), 1, 'first');
end

function entries = asEntryArray(entries)
%ASENTRYARRAY Normalize find() results to something indexable with ().
% find() on a dictionary Section returns an object array, but this
% guards against a cell-array return too.

if iscell(entries)
    if isempty(entries)
        entries = [];
    else
        entries = [entries{:}];
    end
end
end