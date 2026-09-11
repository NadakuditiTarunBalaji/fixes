function [ok, msg] = fixSampleTime(issue, modelsFolder)
%FIXSAMPLETIME Apply a sample-time-related fix identified by
% checkSampleTimes.m.
%
%   [ok, msg] = fixSampleTime(issue, modelsFolder)
%
% issue.FixMethod must be 'InsertUnitDelay' or 'SetOutportConstant'.
% issue.FixData must contain ModelName and OutportPath; InsertUnitDelay
% additionally needs DriverBlockPath.

switch issue.FixMethod
    case 'InsertUnitDelay'
        [ok, msg] = fixByUnitDelay(issue.FixData, modelsFolder);
    case 'SetOutportConstant'
        [ok, msg] = fixByConstantSampleTime(issue.FixData, modelsFolder);
    otherwise
        ok = false;
        msg = sprintf('fixSampleTime: unsupported FixMethod "%s".', issue.FixMethod);
end
end

% =====================================================================
% Fix: Insert a Unit Delay between the constant driver and the Outport
% =====================================================================
function [ok, msg] = fixByUnitDelay(fixData, modelsFolder)
ok = false;
modelName = fixData.ModelName;
outportPath = fixData.OutportPath;
driverPath = fixData.DriverBlockPath;

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
    % A Simulink line only ever connects two blocks within the same
    % immediate diagram, so this must hold - but verify defensively.
    parentSys = get_param(outportPath, 'Parent');
    driverParent = get_param(driverPath, 'Parent');
    if ~strcmp(parentSys, driverParent)
        error('fixSampleTime:ParentMismatch', ...
            'The driver block and the Outport are not in the same system.');
    end

    driverName = get_param(driverPath, 'Name');
    outportName = get_param(outportPath, 'Name');

    portHandles = get_param(outportPath, 'PortHandles');
    inportHandle = portHandles.Inport;
    lineHandle = get_param(inportHandle, 'LineHandle');

    driverPos = get_param(driverPath, 'Position');
    outportPos = get_param(outportPath, 'Position');

    udX = round((driverPos(3) + outportPos(1)) / 2) - 20;
    udY = round(outportPos(2)) - 10;
    udPos = [udX, udY, udX + 40, udY + 20];

    udName = 'UnitDelay_Fix';
    suffix = 1;
    while ~isempty(find_system(parentSys, 'SearchDepth', 1, 'Name', udName))
        suffix = suffix + 1;
        udName = sprintf('UnitDelay_Fix_%d', suffix);
    end

    add_block('built-in/UnitDelay', [parentSys '/' udName], 'Position', udPos);
    delete_line(lineHandle);
    % Names below are relative to parentSys, as add_line requires -
    % NOT the full block paths (that was the original bug).
    add_line(parentSys, [driverName '/1'], [udName '/1'], 'autorouting', 'on');
    add_line(parentSys, [udName '/1'], [outportName '/1'], 'autorouting', 'on');

    save_system(modelName);
    ok = true;
    msg = sprintf('Inserted Unit Delay "%s" in "%s" (model "%s").', ...
        udName, parentSys, modelName);
catch fixErr
    msg = sprintf('Failed to insert Unit Delay: %s', fixErr.message);
end

if openedByUs
    try close_system(modelName, 0); catch, end
end
end

% =====================================================================
% Fix: Set the Outport's sample time to Constant (Inf)
% =====================================================================
function [ok, msg] = fixByConstantSampleTime(fixData, modelsFolder)
ok = false;
modelName = fixData.ModelName;
outportPath = fixData.OutportPath;

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
    set_param(outportPath, 'SampleTime', 'Inf');
    save_system(modelName);
    ok = true;
    msg = sprintf(['Set Outport "%s" sample time to Inf (constant) ' ...
        'in model "%s".'], get_param(outportPath, 'Name'), modelName);
catch fixErr
    msg = sprintf('Failed to set sample time: %s', fixErr.message);
end

if openedByUs
    try close_system(modelName, 0); catch, end
end
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