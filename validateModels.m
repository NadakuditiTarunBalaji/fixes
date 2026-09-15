function issues = validateModels(modelsFolder, selectedModels, progressFcn)
%VALIDATEMODELS Orchestrate all validation checks.
%
%   issues = validateModels(modelsFolder, selectedModels, progressFcn)
%
% Dispatches to:
%   checkConfigConsistency(modelsFolder, selectedModels, progressFcn)
%   checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%   checkSLDDConflicts(modelsFolder, progressFcn)   <-- no models arg

    if nargin < 3 || isempty(progressFcn)
        progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
    end

    issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
        'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

    nSteps = 3;

    % --- Step 1: Configuration consistency --------------------------------
    progressFcn(1/nSteps, 'Checking configuration parameters...');
    try
        configIssues = checkConfigConsistency(modelsFolder, selectedModels, ...
            @(pct, msg) progressFcn(pct * 0.33, msg));
        issues = [issues, configIssues]; %#ok<AGROW>
    catch e
        warning('validateModels:ConfigCheck', ...
            'Configuration check failed: %s', e.message);
    end

    % --- Step 2: Sample times ---------------------------------------------
    progressFcn(2/nSteps, 'Checking outport sample times...');
    try
        sampleIssues = checkSampleTimes(modelsFolder, selectedModels, ...
            @(pct, msg) progressFcn(0.33 + pct * 0.34, msg));
        issues = [issues, sampleIssues]; %#ok<AGROW>
    catch e
        warning('validateModels:SampleTimeCheck', ...
            'Sample time check failed: %s', e.message);
    end

    % --- Step 3: SLDD conflicts -------------------------------------------
    progressFcn(3/nSteps, 'Checking data dictionary conflicts...');
    try
        % NOTE: checkSLDDConflicts takes (folder, progressFcn) — NO models list
        slddIssues = checkSLDDConflicts(modelsFolder, ...
            @(pct, msg) progressFcn(0.67 + pct * 0.33, msg));
        issues = [issues, slddIssues]; %#ok<AGROW>
    catch e
        warning('validateModels:SLDDCheck', ...
            'SLDD check failed: %s', e.message);
    end

    progressFcn(1, sprintf('Validation complete: %d issue(s) found.', numel(issues)));
end