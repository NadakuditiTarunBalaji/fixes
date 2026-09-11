function issues = checkSLDDConflicts(modelsFolder, progressFcn)
%CHECKSLDDCONFLICTS Inspects the active DataDictionary parameter on all models,
% loads them, and identifies variable definition range (Min/Max) collisions.

if nargin < 2 || isempty(progressFcn)
    progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
end

issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
    'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

progressFcn(0, 'Resolving attached active data dictionaries...');

% Find all models to retrieve their dict attachments
slxFiles = dir(fullfile(modelsFolder, '**', '*.slx'));
mdlFiles = dir(fullfile(modelsFolder, '**', '*.mdl'));
allModels = [slxFiles; mdlFiles];

uniqueDictPaths = {};
uniqueDictNames = {};

for i = 1:numel(allModels)
    [~, mName] = fileparts(allModels(i).name);
    try
        openedByUs = false;
        if ~bdIsLoaded(mName)
            load_system(fullfile(allModels(i).folder, allModels(i).name));
            openedByUs = true;
        end
        
        attachedDict = get_param(mName, 'DataDictionary');
        if ~isempty(attachedDict)
            resolvedPath = which(attachedDict);
            if ~isempty(resolvedPath) && ~any(strcmp(uniqueDictPaths, resolvedPath))
                uniqueDictPaths{end+1} = resolvedPath; %#ok<AGROW>
                [~, namePart, extPart] = fileparts(resolvedPath);
                uniqueDictNames{end+1} = [namePart extPart]; %#ok<AGROW>
            end
        end
        
        if openedByUs
            close_system(mName, 0);
        end
    catch
    end
end

% Also scan folder to catch unattached dictionaries
localSldds = dir(fullfile(modelsFolder, '**', '*.sldd'));
for k = 1:numel(localSldds)
    resolvedPath = fullfile(localSldds(k).folder, localSldds(k).name);
    if ~any(strcmp(uniqueDictPaths, resolvedPath))
        uniqueDictPaths{end+1} = resolvedPath; %#ok<AGROW>
        uniqueDictNames{end+1} = localSldds(k).name; %#ok<AGROW>
    end
end

if isempty(uniqueDictPaths)
    issues(end + 1) = struct( ...
        'Category', 'Info', 'Severity', 'info', ...
        'Model', 'N/A', 'Port', '', ...
        'Description', 'No active or local .sldd dictionaries found. Check skipped.', ...
        'FixMethod', 'none', 'FixData', struct());
    progressFcn(1, 'No .sldd files found.');
    return;
end

allDefs = containers.Map('KeyType', 'char', 'ValueType', 'any');

for i = 1:numel(uniqueDictPaths)
    dictPath = uniqueDictPaths{i};
    dictName = uniqueDictNames{i};
    progressFcn((i - 1) / numel(uniqueDictPaths), sprintf('Scanning dictionary: %s', dictName));

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
            'Description', sprintf('Could not read dict "%s": %s', dictName, dictErr.message), ...
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
        continue;   
    end

    masterIdx = pickMasterDefinition(minStrings, maxStrings);
    dictNames = {defs.DictName};

    issues(end + 1) = struct( ... %#ok<AGROW>
        'Category', 'SLDD', ...
        'Severity', 'error', ...
        'Model', symName, ...
        'Port', '', ...
        'Description', sprintf(['Symbol "%s" has inconsistent range values ' ...
            'between active dictionaries: %s. Master source chosen: %s (Min=%s, Max=%s)'], ...
            symName, strjoin(dictNames, ', '), defs(masterIdx).DictName, ...
            mat2str(defs(masterIdx).Min), mat2str(defs(masterIdx).Max)), ...
        'FixMethod', 'SyncToMaster', ...
        'FixData', struct( ...
            'Symbol', symName, ...
            'Definitions', defs, ...
            'MasterIndex', masterIdx));
end

progressFcn(1, sprintf('SLDD analysis completed: %d active files checked.', numel(uniqueDictPaths)));
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
if iscell(entries)
    if isempty(entries), entries = []; else, entries = [entries{:}]; end
end
end