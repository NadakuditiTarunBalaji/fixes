function results = applyFixes(issues, modelsFolder, progressFcn)
%APPLYFIXES Applies the selected fix to each fixable issue.
%
%   results = applyFixes(issues, modelsFolder)
%   results = applyFixes(issues, modelsFolder, progressFcn)
%
%   results(i).Success — true/false
%   results(i).Message — description of what was done
%
% Dispatches to fixSampleTime.m ('InsertUnitDelay' / 'SetOutportConstant'),
% fixSLDDConflict.m ('SyncToMaster'), and a small inline handler for
% 'MatchParent' (a single set_param call, kept here since it has no
% dedicated file).

if nargin < 3 || isempty(progressFcn)
    progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
end

results = struct('Success', {}, 'Message', {});
fixable = issues(~strcmp({issues.FixMethod}, 'none'));
nFixes = numel(fixable);

if nFixes == 0
    results(1) = struct('Success', true, 'Message', 'No fixable issues.');
    return;
end

for i = 1:nFixes
    issue = fixable(i);
    progressFcn((i - 1) / nFixes, sprintf('Fixing %d/%d: %s [%s]', ...
        i, nFixes, issue.Model, issue.FixMethod));

    try
        switch issue.FixMethod
            case {'InsertUnitDelay', 'SetOutportConstant'}
                [ok, msg] = fixSampleTime(issue, modelsFolder);

            case 'SyncToMaster'
                [ok, msg] = fixSLDDConflict(issue);

            case 'MatchParent'
                [ok, msg] = fixConfigParameter(issue, modelsFolder);

            otherwise
                ok = false;
                msg = sprintf('Unknown fix method: %s', issue.FixMethod);
        end
    catch fixErr
        ok = false;
        msg = sprintf('Fix failed: %s', fixErr.message);
    end

    results(end + 1) = struct('Success', ok, 'Message', msg); %#ok<AGROW>
end

progressFcn(1, sprintf('Applied %d fixes. %d succeeded, %d failed.', ...
    nFixes, sum([results.Success]), sum(~[results.Success])));
end

% =====================================================================
% Fix: Match Config Parameters to Parent (majority value)
% =====================================================================
function [ok, msg] = fixConfigParameter(issue, modelsFolder)
ok = false;
fixData = issue.FixData;
modelName = fixData.ModelName;
paramName = fixData.ParamName;
targetValue = fixData.TargetValue;

modelFile = findModelFileOnDisk(modelsFolder, modelName);
if isempty(modelFile)
    msg = sprintf('Model file not found: %s', modelName);
    return;
end

openedByUs = false;
if ~bdIsLoaded(modelName)
    load_system(modelFile);
    openedByUs = true;
end

try
    set_param(modelName, paramName, targetValue);
    save_system(modelName);
    ok = true;
    msg = sprintf('Set "%s" = "%s" in model "%s".', paramName, targetValue, modelName);
catch fixErr
    msg = sprintf('Failed to set config: %s', fixErr.message);
end

if openedByUs
    try close_system(modelName, 0); catch, end
end
end

% =====================================================================
% Helper
% =====================================================================
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