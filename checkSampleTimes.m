function issues = checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%CHECKSAMPLETIMES Detect root Outports fed directly by a Constant/Ground
% block. Such an Outport has a constant/inherited sample time and can
% cause a sample time mismatch when the model is referenced from a
% discrete parent model.
%
%   issues = checkSampleTimes(modelsFolder, selectedModels)
%   issues = checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%
% progressFcn(fraction, message) reports progress in [0, 1] for this
% function's own work only.

if nargin < 3 || isempty(progressFcn)
    progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
end
if ischar(selectedModels)
    selectedModels = {selectedModels};
end

issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
    'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

numModels = numel(selectedModels);
if numModels == 0
    return;
end

for i = 1:numModels
    modelName = selectedModels{i};
    progressFcn((i - 1) / numModels, sprintf('Sample time: %s (%d/%d)', ...
        modelName, i, numModels));

    openedByUs = false;
    try
        if ~bdIsLoaded(modelName)
            modelFile = findModelFileOnDisk(modelsFolder, modelName);
            if isempty(modelFile)
                issues(end + 1) = struct( ... %#ok<AGROW>
                    'Category', 'Info', 'Severity', 'warning', ...
                    'Model', modelName, 'Port', '', ...
                    'Description', sprintf( ...
                        'Model file not found for "%s" - sample time check skipped.', ...
                        modelName), ...
                    'FixMethod', 'none', 'FixData', struct());
                continue;
            end
            load_system(modelFile);
            openedByUs = true;
        end

        outportPaths = find_system(modelName, 'SearchDepth', 1, ...
            'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Outport');
        if ischar(outportPaths)
            outportPaths = {outportPaths};
        end

        for j = 1:numel(outportPaths)
            outportPath = outportPaths{j};
            outportName = get_param(outportPath, 'Name');

            try
                portHandles = get_param(outportPath, 'PortHandles');
                inportHandle = portHandles.Inport;
                if isempty(inportHandle)
                    continue;
                end

                lineHandle = get_param(inportHandle, 'LineHandle');
                if isempty(lineHandle) || lineHandle == -1
                    continue;
                end

                srcPortHandle = get_param(lineHandle, 'SrcPortHandle');
                if isempty(srcPortHandle) || srcPortHandle == -1
                    continue;
                end

                srcBlockPath = get_param(srcPortHandle, 'Parent');
                srcBlockType = get_param(srcBlockPath, 'BlockType');

                isConstantDriver = strcmp(srcBlockType, 'Constant') || ...
                    strcmp(srcBlockType, 'Ground');

                if isConstantDriver
                    outportST = strtrim(get_param(outportPath, 'SampleTime'));
                    if isempty(outportST) || strcmp(outportST, '-1')
                        issues(end + 1) = struct( ... %#ok<AGROW>
                            'Category', 'SampleTime', ...
                            'Severity', 'error', ...
                            'Model', modelName, ...
                            'Port', outportName, ...
                            'Description', sprintf(['Outport "%s" in model ' ...
                                '"%s" is driven directly by a %s block ' ...
                                '(constant sample time). When referenced ' ...
                                'from a discrete parent, this can cause a ' ...
                                'sample time mismatch.'], ...
                                outportName, modelName, srcBlockType), ...
                            'FixMethod', 'InsertUnitDelay', ...
                            'FixData', struct( ...
                                'ModelName', modelName, ...
                                'OutportPath', outportPath, ...
                                'DriverBlockPath', srcBlockPath, ...
                                'DriverType', srcBlockType));
                    end
                end
            catch
                % A single port that cannot be traced should not abort
                % the whole scan - skip it and move on.
            end
        end

        if openedByUs
            close_system(modelName, 0);
        end
    catch modelErr
        if openedByUs
            try close_system(modelName, 0); catch, end
        end
        issues(end + 1) = struct( ... %#ok<AGROW>
            'Category', 'Info', 'Severity', 'warning', ...
            'Model', modelName, 'Port', '', ...
            'Description', sprintf('Could not fully analyze model "%s": %s', ...
                modelName, modelErr.message), ...
            'FixMethod', 'none', 'FixData', struct());
    end
end

progressFcn(1, 'Sample time check complete.');
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