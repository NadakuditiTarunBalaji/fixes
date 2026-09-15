function createValidationTestCase()
%CREATEVALIDATIONTESTCASE Build a folder of Simulink models that intentionally
% trigger every kind of issue Validate First is supposed to catch.

    testRoot = fullfile(pwd, 'ValidationTestModels');
    if isfolder(testRoot)
        rmdir(testRoot, 's');
    end
    mkdir(testRoot);

    fprintf('Creating test case in:\n  %s\n\n', testRoot);

    % --- 1. Create two SLDDs that conflict on the same symbol -----------
    createConflictingSLDDs(testRoot);

    % <-- FIX: cd into testRoot so models can find the .sldd files
    origDir = pwd;
    cd(testRoot);
    cleanupObj = onCleanup(@() cd(origDir));

    % --- 2. Create the models that reference those SLDDs ----------------
    createModel_A(testRoot);
    createModel_B(testRoot);
    createModel_C(testRoot);
    createModel_D(testRoot);

    fprintf('\nDone.\n');
    fprintf('Now launch teamtools, point "Models folder" at:\n  %s\n', testRoot);
    fprintf('then Add All and click "Validate First".\n');
end

% =========================================================================
%  1) SLDD CONFLICTS
% =========================================================================
function createConflictingSLDDs(testRoot)
    fprintf('[1] Creating SLDDs with conflicting symbol "SharedGain"...\n');

    dictAPath = fullfile(testRoot, 'DictA.sldd');
    dictBPath = fullfile(testRoot, 'DictB.sldd');

    % --- DictA: SharedGain = double, Min=0, Max=10 ----------------------
    dictA = Simulink.data.dictionary.create(dictAPath);
    sec = getSection(dictA, 'Design Data');

    paramA = Simulink.Parameter;
    paramA.Value = 1;
    paramA.DataType = 'double';
    paramA.Min = 0;
    paramA.Max = 10;
    addEntry(sec, 'SharedGain', paramA);

    sigA = Simulink.Signal;
    sigA.DataType = 'double';
    sigA.Min = -100;
    sigA.Max =  100;
    addEntry(sec, 'SignalFromA', sigA);

    saveChanges(dictA);
    close(dictA);

    % --- DictB: SharedGain = single, Min=-5, Max=50  (CONFLICT) ---------
    dictB = Simulink.data.dictionary.create(dictBPath);
    sec = getSection(dictB, 'Design Data');

    paramB = Simulink.Parameter;
    paramB.Value = 2;
    paramB.DataType = 'single';
    paramB.Min = -5;
    paramB.Max = 50;
    addEntry(sec, 'SharedGain', paramB);

    sigB = Simulink.Signal;
    sigB.DataType = 'double';
    sigB.Min = 0;
    sigB.Max = 1;
    addEntry(sec, 'SignalFromB', sigB);

    saveChanges(dictB);
    close(dictB);

    fprintf('    DictA.sldd : SharedGain = double, [0..10]\n');
    fprintf('    DictB.sldd : SharedGain = single, [-5..50]  <-- CONFLICT\n');
end

% =========================================================================
%  2) Model A - baseline, valid, links DictA
% =========================================================================
function createModel_A(~)
    fprintf('[2] Creating ModelA (baseline)...\n');
    name = 'ModelA';

    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.01');
    set_param(name, 'StartTime', '0.0');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'off');

    set_param(name, 'DataDictionary', 'DictA.sldd');

    add_block('simulink/Sources/In1',  [name '/InA'],  'Position', [40  50  70  70]);
    add_block('simulink/Math Operations/Gain', [name '/GainA'], ...
        'Position', [130 45  180 75], 'Gain', 'SharedGain');
    add_block('simulink/Sinks/Out1',   [name '/OutA'], ...
        'Position', [240 50  270 70], 'SampleTime', '0.01');

    add_line(name, 'InA/1',   'GainA/1');
    add_line(name, 'GainA/1', 'OutA/1');

    save_system(name, [name '.slx']);
    close_system(name, 0);
    fprintf('    ModelA saved (FixedStep=0.01, Division=off, DictA).\n');
end

% =========================================================================
%  3) Model B - CONFIG MISMATCH + links DictB (SLDD conflict)
% =========================================================================
function createModel_B(~)
    fprintf('[3] Creating ModelB (config mismatch + DictB link)...\n');
    name = 'ModelB';

    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    % <-- Deliberately DIFFERENT config than ModelA
    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.02');                       % <-- differs
    set_param(name, 'StartTime', '0.0');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'on');  % <-- differs

    set_param(name, 'DataDictionary', 'DictB.sldd');

    add_block('simulink/Sources/In1',  [name '/InB'],  'Position', [40  50  70  70]);
    add_block('simulink/Math Operations/Gain', [name '/GainB'], ...
        'Position', [130 45  180 75], 'Gain', 'SharedGain');
    add_block('simulink/Sinks/Out1',   [name '/OutB'], ...
        'Position', [240 50  270 70], 'SampleTime', '0.02');

    add_line(name, 'InB/1',   'GainB/1');
    add_line(name, 'GainB/1', 'OutB/1');

    save_system(name, [name '.slx']);
    close_system(name, 0);
    fprintf('    ModelB saved (FixedStep=0.02, Division=on, DictB).\n');
    fprintf('    -> Config mismatch with ModelA + SLDD conflict on SharedGain.\n');
end

% =========================================================================
%  4) Model C - OUTPORT with INHERITED (-1) sample time
% =========================================================================
function createModel_C(~)
    fprintf('[4] Creating ModelC (inherited outport sample time)...\n');
    name = 'ModelC';

    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.01');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'off');

    add_block('simulink/Sources/In1',  [name '/InC'],  'Position', [40 50  70 70]);
    add_block('simulink/Math Operations/Gain', [name '/GainC'], ...
        'Position', [130 45 180 75], 'Gain', '2');
    add_block('simulink/Sinks/Out1', [name '/OutC'], ...
        'Position', [240 50 270 70], 'SampleTime', '-1');  % <-- inherited

    add_line(name, 'InC/1',   'GainC/1');
    add_line(name, 'GainC/1', 'OutC/1');

    save_system(name, [name '.slx']);
    close_system(name, 0);
    fprintf('    ModelC saved (OutC.SampleTime = -1 inherited).\n');
end

% =========================================================================
%  5) Model D - feedback loop candidate (cross-model cycle)
%    Port names are chosen so that in the parent model:
%      ModelC.OutC  ->  ModelD.InD     (forward)
%      ModelD.OutD  ->  ModelC.InC     (backward = algebraic loop risk)
%    This is detected by checkSampleTimes as a feedback/algebraic issue.
% =========================================================================
function createModel_D(~)
    fprintf('[5] Creating ModelD (feedback loop candidate)...\n');
    name = 'ModelD';

    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.01');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'off');

    % <-- FIX: unique block names, but port names that create a cycle
    % when combined with ModelC in the parent model
    add_block('simulink/Sources/In1',  [name '/InD'], ...
        'Position', [40  50  70  70]);
    add_block('simulink/Math Operations/Gain', [name '/GainD'], ...
        'Position', [130 45  180 75], 'Gain', '0.5');
    add_block('simulink/Sinks/Out1', [name '/OutD'], ...
        'Position', [240 50  270 70], 'SampleTime', '-1');  % <-- also inherited

    add_line(name, 'InD/1',   'GainD/1');
    add_line(name, 'GainD/1', 'OutD/1');

    save_system(name, [name '.slx']);
    close_system(name, 0);
    fprintf('    ModelD saved (OutD.SampleTime = -1 inherited).\n');
    fprintf('    -> Together with ModelC, creates a feedback cycle in the parent.\n');
end