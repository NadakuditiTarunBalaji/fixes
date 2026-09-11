function issues = checkConfigConsistency(modelsFolder, selectedModels, progressFcn)
%CHECKCONFIGCONSISTENCY Flag configuration parameters that differ from
% the majority value across the selected models (e.g. mixed solver
% types), which a multi-model build can otherwise silently paper over.
%
%   issues = checkConfigConsistency(modelsFolder, selectedModels)
%   issues = checkConfigConsistency(modelsFolder, selectedModels, progressFcn)
%
% Only a small, fixed set of parameters is compared - the ones most
% likely to break a multi-model reference build. Extend CHECKED_PARAMS
% to cover more; parameters that don't apply to a given model's solver
% (e.g. FixedStep on a variable-step model) are silently skipped for
% that model.

if nargin < 3 || isempty(progressFcn)
    progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
end
if ischar(selectedModels)
    selectedModels = {selectedModels};
end

issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
    'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

numModels = numel(selectedModels);
if numModels < 2
    progressFcn(1, 'Only one model selected - nothing to compare.');
    return;
end

CHECKED_PARAMS = {'SolverType', 'Solver'};

paramValues = containers.Map('KeyType', 'char', 'ValueType', 'any');
for p = 1:numel(CHECKED_PARAMS)
    paramValues(CHECKED_PARAMS{p}) = struct('Model', {}, 'Value', {});
end

for i = 1:numModels
    modelName = selectedModels{i};
    progressFcn((i - 1) / numModels, sprintf('Config: %s (%d/%d)', ...
        modelName, i, numModels));

    openedByUs = false;
    try
        if ~bdIsLoaded(modelName)
            modelFile = findModelFileOnDisk(modelsFolder, modelName);
            if isempty(modelFile)
                continue;
            end
            load_system(modelFile);
            openedByUs = true;
        end

        for p = 1:numel(CHECKED_PARAMS)
            paramName = CHECKED_PARAMS{p};
            try
                value = get_param(modelName, paramName);
            catch
                continue;   % parameter not applicable to this model
            end
            entries = paramValues(paramName);
            entries(end + 1) = struct('Model', modelName, 'Value', value); %#ok<AGROW>
            paramValues(paramName) = entries;
        end

        if openedByUs
            close_system(modelName, 0);
        end
    catch
        if openedByUs
            try close_system(modelName, 0); catch, end
        end
    end
end

for p = 1:numel(CHECKED_PARAMS)
    paramName = CHECKED_PARAMS{p};
    entries = paramValues(paramName);
    if numel(entries) < 2
        continue;
    end
    values = {entries.Value};
    uniqueValues = unique(values);
    if numel(uniqueValues) <= 1
        continue;   % everyone agrees
    end

    counts = cellfun(@(v) sum(strcmp(values, v)), uniqueValues);
    [~, majorityIndex] = max(counts);
    majorityValue = uniqueValues{majorityIndex};

    for e = 1:numel(entries)
        if ~strcmp(entries(e).Value, majorityValue)
            issues(end + 1) = struct( ... %#ok<AGROW>
                'Category', 'Config', ...
                'Severity', 'warning', ...
                'Model', entries(e).Model, ...
                'Port', '', ...
                'Description', sprintf( ...
                    '%s = "%s" differs from the majority ("%s", used by %d of %d models).', ...
                    paramName, entries(e).Value, majorityValue, ...
                    counts(majorityIndex), numel(entries)), ...
                'FixMethod', 'MatchParent', ...
                'FixData', struct( ...
                    'ModelName', entries(e).Model, ...
                    'ParamName', paramName, ...
                    'TargetValue', majorityValue));
        end
    end
end

progressFcn(1, 'Configuration consistency check complete.');
end

function modelFile = findModelFileOnDisk(modelsFolder, modelName)
modelFile = '';
candidates = dir(fullfile(modelsFolder, '**', [modelName '.slx']));
if isempty(candidates)
    candidates = dir(fullfile(modelsFolder, '**', [modelName '.mdl']));
end
candidates = candidates(~[candidates.isdir]);
if ~isempty(candidates)
    modelFile = fullfile(candidates(1).folder, candidates(1).name);
end
end