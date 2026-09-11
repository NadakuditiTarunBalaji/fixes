function issues = validateModels(modelsFolder, selectedModels, progressFcn)
%VALIDATEMODELS Pre-build validation: sample times, config consistency,
% and SLDD conflicts.
%
%   issues = validateModels(modelsFolder, selectedModels)
%   issues = validateModels(modelsFolder, selectedModels, progressFcn)
%
% Delegates to checkSampleTimes.m, checkConfigConsistency.m, and
% checkSLDDConflicts.m, and merges their results into one struct array:
%
%   issues(i).Category    — 'SampleTime' | 'Config' | 'SLDD' | 'Info'
%   issues(i).Severity    — 'error' | 'warning' | 'info'
%   issues(i).Model       — model name or symbol name
%   issues(i).Port        — port name (may be '')
%   issues(i).Description — human-readable description
%   issues(i).FixMethod   — 'InsertUnitDelay' | 'SetOutportConstant' |
%                           'SyncToMaster' | 'MatchParent' | 'none'
%   issues(i).FixData     — struct with the data applyFixes.m needs

if nargin < 3 || isempty(progressFcn)
    progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
end

if ischar(selectedModels)
    selectedModels = {selectedModels};
end
selectedModels = regexprep(selectedModels, '\.(slx|mdl)$', '', 'ignorecase');

issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
    'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

% Stage weighting within the overall progress bar.
stStart = 0.00; stSpan = 0.40;    % sample times
cfgStart = 0.40; cfgSpan = 0.20;  % config consistency
slddStart = 0.60; slddSpan = 0.40; % SLDD conflicts

progressFcn(stStart, 'Checking sample times...');
sampleTimeIssues = checkSampleTimes(modelsFolder, selectedModels, ...
    @(f, m) progressFcn(stStart + f * stSpan, m));
issues = [issues, sampleTimeIssues];

progressFcn(cfgStart, 'Checking configuration consistency...');
configIssues = checkConfigConsistency(modelsFolder, selectedModels, ...
    @(f, m) progressFcn(cfgStart + f * cfgSpan, m));
issues = [issues, configIssues];

progressFcn(slddStart, 'Checking SLDD dictionaries...');
slddIssues = checkSLDDConflicts(modelsFolder, ...
    @(f, m) progressFcn(slddStart + f * slddSpan, m));
issues = [issues, slddIssues];

nErrors = sum(strcmp({issues.Severity}, 'error'));
nWarnings = sum(strcmp({issues.Severity}, 'warning'));
nInfo = sum(strcmp({issues.Severity}, 'info'));
progressFcn(1.0, sprintf('Validation complete: %d errors, %d warnings, %d info', ...
    nErrors, nWarnings, nInfo));
end