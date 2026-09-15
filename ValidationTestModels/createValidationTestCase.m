function createValidationTestCase()
%CREATEVALIDATIONTESTCASE Build a folder of Simulink models that intentionally
% trigger every kind of issue Validate First is supposed to catch:
%
%   1) Config parameter mismatch    (checkConfigConsistency.m)
%   2) Outport sample-time issues   (checkSampleTimes.m)
%   3) SLDD conflicts               (checkSLDDConflicts.m)
%
% Usage:
%   >> createValidationTestCase
%   >> teamtools
%   Point "Models folder" at ValidationTestModels, Add All, Validate First.

    testRoot = fullfile(pwd, 'ValidationTestModels');
    if isfolder(testRoot)
        rmdir(testRoot, 's');
    end
    mkdir(testRoot);

    fprintf('Creating test case in:\n  %s\n\n', testRoot);

    % --- 1. Create two SLDDs that conflict on the same symbol -----------
    createConflictingSLDDs(testRoot);

    % --- 2. Create the models that reference those SLDDs ----------------
    createModel_A(testRoot);   % baseline model, links to DictA.sldd
    createModel_B(testRoot);   % config mismatch, links to DictB.sldd
    createModel_C(testRoot);   % outport with inherited sample time
    createModel_D(testRoot);   % feedback loop candidate

    fprintf('\nDone.\n');
    fprintf('Now launch teamtools, point "Models folder" at:\n  %s\n', testRoot);
    fprintf('then Add All and click "Validate First".\n');
end

% =========================================================================
%  1) SLDD CONFLICTS - two dictionaries define the SAME symbol differently
% =========================================================================
function createConflictingSLDDs(testRoot)
    fprintf('[1] Creating SLDDs with conflicting symbol "SharedGain"...\n');

    dictAPath = fullfile(testRoot, 'DictA.sldd');
    dictBPath = fullfile(testRoot, 'DictB.sldd');

    % --- DictA: SharedGain as Simulink.Parameter, Min=0, Max=10 ---------
    dictA = Simulink.data.dictionary.create(dictAPath);
    sec = getSection(dictA, 'Design Data');

    paramA = Simulink.Parameter;
    paramA.Value = 1;
    paramA.DataType = 'double';
    paramA.Min = 0;
    paramA.Max = 10;
    addEntry(sec, 'SharedGain', paramA);

    % A signal that only DictA has, to make the models actually reference it
    sigA = Simulink.Signal;
    sigA.DataType = 'double';
    sigA.Min = -100;
    sigA.Max =  100;
    addEntry(sec, 'SignalFromA', sigA);

    saveChanges(dictA);
    close(dictA);

    % --- DictB: SharedGain SAME NAME but Min=-5, Max=50, single ---------
    dictB = Simulink.data.dictionary.create(dictBPath);
    sec = getSection(dictB, 'Design Data');

    paramB = Simulink.Parameter;
    paramB.Value = 2;
    paramB.DataType = 'single';     % <-- conflicting DataType
    paramB.Min = -5;                % <-- conflicting Min
    paramB.Max = 50;                % <-- conflicting Max
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
function createModel_A(testRoot)
    fprintf('[2] Creating ModelA (baseline)...\n');
    name = 'ModelA';
    file = fullfile(testRoot, [name '.slx']);

    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    % Baseline configuration - explicit fixed step 0.01
    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.01');
    set_param(name, 'StartTime', '0.0');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'off');

    % Attach the dictionary
    set_param(name, 'DataDictionary', 'DictA.sldd');

    % Simple content: Inport -> Gain -> Outport (with a valid sample time)
    add_block('simulink/Sources/In1',  [name '/InA'],  'Position', [40  50  70  70]);
    add_block('simulink/Math Operations/Gain', [name '/GainA'], ...
        'Position', [130 45  180 75], 'Gain', 'SharedGain');
    add_block('simulink/Sinks/Out1',   [name '/OutA'], ...
        'Position', [240 50  270 70], 'SampleTime', '0.01');

    add_line(name, 'InA/1',    'GainA/1');
    add_line(name, 'GainA/1',  'OutA/1');

    save_system(name, file);
    close_system(name, 0);
    fprintf('    ModelA saved (FixedStep=0.01, UseDivisionForNetSlopeComputation=off).\n');
end

% =========================================================================
%  3) Model B - CONFIG MISMATCH + links DictB (SLDD conflict)
% =========================================================================
function createModel_B(testRoot)
    fprintf('[3] Creating ModelB (config mismatch + DictB link)...\n');
    name = 'ModelB';
    file = fullfile(testRoot, [name '.slx']);

    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    % Deliberately DIFFERENT config than ModelA
    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.02');                      % <-- differs
    set_param(name, 'StartTime', '0.0');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'on'); % <-- differs

    % Attach the OTHER dictionary that conflicts with DictA
    set_param(name, 'DataDictionary', 'DictB.sldd');

    add_block('simulink/Sources/In1',  [name '/InB'],  'Position', [40  50  70  70]);
    add_block('simulink/Math Operations/Gain', [name '/GainB'], ...
        'Position', [130 45  180 75], 'Gain', 'SharedGain');    % same symbol name
    add_block('simulink/Sinks/Out1',   [name '/OutB'], ...
        'Position', [240 50  270 70], 'SampleTime', '0.02');

    add_line(name, 'InB/1',    'GainB/1');
    add_line(name, 'GainB/1',  'OutB/1');

    save_system(name, file);
    close_system(name, 0);
    fprintf('    ModelB saved (FixedStep=0.02, UseDivisionForNetSlopeComputation=on).\n');
    fprintf('    -> Config mismatch with ModelA + SLDD conflict on SharedGain.\n');
end

% =========================================================================
%  4) Model C - OUTPORT with INHERITED (-1) sample time
% =========================================================================
function createModel_C(testRoot)
    fprintf('[4] Creating ModelC (inherited outport sample time)...\n');
    name = 'ModelC';
    file = fullfile(testRoot, [name '.slx']);

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
    % Outport left as SampleTime = -1 (inherited) -> validator flags it
    add_block('simulink/Sinks/Out1', [name '/OutC'], ...
        'Position', [240 50 270 70], 'SampleTime', '-1');

    add_line(name, 'InC/1',   'GainC/1');
    add_line(name, 'GainC/1', 'OutC/1');

    save_system(name, file);
    close_system(name, 0);
    fprintf('    ModelC saved (OutC.SampleTime = -1 inherited).\n');
end

% =========================================================================
%  5) Model D - self-feedback candidate (algebraic loop risk)
% =========================================================================
function createModel_D(testRoot)
    fprintf('[5] Creating ModelD (feedback loop candidate)...\n');
    name = 'ModelD';
    file = fullfile(testRoot, [name '.slx']);

    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.01');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'off');

    % Same-named inport / outport so a downstream connection maps input <- output,
    % which is what teamtools' auto-delay / loop breaker looks at.
    add_block('simulink/Sources/In1',  [name '/FeedbackSignal'], ...
        'Position', [40  50  90  70]);
    add_block('simulink/Math Operations/Sum', [name '/SumD'], ...
        'Position', [140 40  170 80], 'Inputs', '++');
    add_block('simulink/Sinks/Out1', [name '/FeedbackSignal'], ...
        'Position', [220 50  270 70], 'SampleTime', '0.01');

    add_line(name, 'FeedbackSignal/1', 'SumD/1');
    add_line(name, 'SumD/1',           'FeedbackSignal/1');

    save_system(name, file);
    close_system(name, 0);
    fprintf(['    ModelD saved (inport & outport named "FeedbackSignal" -> ', ...
        'in the generated parent, its output feeds its own input).\n']);
end