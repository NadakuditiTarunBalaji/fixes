function createValidationTestCase()
%CREATEVALIDATIONTESTCASE Build models that trigger all three checkers.

    testRoot = fullfile(pwd, 'ValidationTestModels');
    if isfolder(testRoot)
        rmdir(testRoot, 's');
    end
    mkdir(testRoot);

    fprintf('Creating test case in:\n  %s\n\n', testRoot);

    createConflictingSLDDs(testRoot);

    origDir = pwd;
    cd(testRoot);
    cleanupObj = onCleanup(@() cd(origDir));

    createModel_A(testRoot);
    createModel_B(testRoot);
    createModel_C(testRoot);

    fprintf('\nDone.\n');
    fprintf('Now launch teamtools, point "Models folder" at:\n  %s\n', testRoot);
    fprintf('then Add All and click "Validate First".\n');
end

% =========================================================================
%  SLDD CONFLICTS
% =========================================================================
function createConflictingSLDDs(testRoot)
    fprintf('[1] Creating SLDDs with conflicting symbol "SharedGain"...\n');

    dictAPath = fullfile(testRoot, 'DictA.sldd');
    dictBPath = fullfile(testRoot, 'DictB.sldd');

    dictA = Simulink.data.dictionary.create(dictAPath);
    sec = getSection(dictA, 'Design Data');
    paramA = Simulink.Parameter;
    paramA.Value = 1;
    paramA.DataType = 'double';
    paramA.Min = 0;
    paramA.Max = 10;
    addEntry(sec, 'SharedGain', paramA);
    saveChanges(dictA);
    close(dictA);

    dictB = Simulink.data.dictionary.create(dictBPath);
    sec = getSection(dictB, 'Design Data');
    paramB = Simulink.Parameter;
    paramB.Value = 2;
    paramB.DataType = 'single';
    paramB.Min = -5;
    paramB.Max = 50;
    addEntry(sec, 'SharedGain', paramB);
    saveChanges(dictB);
    close(dictB);

    fprintf('    DictA: SharedGain = double, [0..10]\n');
    fprintf('    DictB: SharedGain = single, [-5..50]  <-- CONFLICT\n');
end

% =========================================================================
%  Model A - baseline (FixedStep=0.01, Division=off, DictA)
% =========================================================================
function createModel_A(~)
    fprintf('[2] Creating ModelA (baseline)...\n');
    name = 'ModelA';
    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.01');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'off');
    set_param(name, 'DataDictionary', 'DictA.sldd');

    add_block('simulink/Sources/In1', [name '/InA'], 'Position', [40 50 70 70]);
    add_block('simulink/Math Operations/Gain', [name '/GainA'], ...
        'Position', [130 45 180 75], 'Gain', 'SharedGain');
    add_block('simulink/Sinks/Out1', [name '/OutA'], ...
        'Position', [240 50 270 70], 'SampleTime', '0.01');

    add_line(name, 'InA/1', 'GainA/1');
    add_line(name, 'GainA/1', 'OutA/1');

    save_system(name, [name '.slx']);
    close_system(name, 0);
    fprintf('    ModelA: FixedStep=0.01, Division=off, DictA\n');
end

% =========================================================================
%  Model B - CONFIG MISMATCH (FixedStep=0.02, Division=on, DictB)
% =========================================================================
function createModel_B(~)
    fprintf('[3] Creating ModelB (config mismatch + DictB)...\n');
    name = 'ModelB';
    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.02');                        % <-- differs
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'on');    % <-- differs
    set_param(name, 'DataDictionary', 'DictB.sldd');

    add_block('simulink/Sources/In1', [name '/InB'], 'Position', [40 50 70 70]);
    add_block('simulink/Math Operations/Gain', [name '/GainB'], ...
        'Position', [130 45 180 75], 'Gain', 'SharedGain');
    add_block('simulink/Sinks/Out1', [name '/OutB'], ...
        'Position', [240 50 270 70], 'SampleTime', '0.02');

    add_line(name, 'InB/1', 'GainB/1');
    add_line(name, 'GainB/1', 'OutB/1');

    save_system(name, [name '.slx']);
    close_system(name, 0);
    fprintf('    ModelB: FixedStep=0.02, Division=on, DictB\n');
end

% =========================================================================
%  Model C - OUTPORT with constant-driven inherited sample time
%  This triggers checkSampleTimes.m's compilation diagnostic:
%  a Constant block drives an Outport with SampleTime=-1, which
%  Simulink flags as "Invalid root Outport block connection" when
%  the model is referenced from a parent.
% =========================================================================
function createModel_C(~)
    fprintf('[4] Creating ModelC (constant-driven inherited outport)...\n');
    name = 'ModelC';
    if bdIsLoaded(name), close_system(name, 0); end
    new_system(name);

    set_param(name, 'SolverType', 'Fixed-step');
    set_param(name, 'Solver', 'FixedStepDiscrete');
    set_param(name, 'FixedStep', '0.01');
    set_param(name, 'StopTime', '10');
    set_param(name, 'UseDivisionForNetSlopeComputation', 'off');

    % Constant block -> Outport with inherited sample time
    % When compiled in a parent, Simulink detects the constant-rate
    % signal driving an inherited outport and raises a diagnostic.
    add_block('simulink/Sources/Constant', [name '/Const'], ...
        'Position', [40 50 80 70], 'Value', '1');
    add_block('simulink/Sinks/Out1', [name '/OutC'], ...
        'Position', [160 50 190 70], 'SampleTime', '-1');

    add_line(name, 'Const/1', 'OutC/1');

    save_system(name, [name '.slx']);
    close_system(name, 0);
    fprintf('    ModelC: Constant -> OutC (SampleTime=-1)\n');
    fprintf('    -> Triggers "Invalid root Outport" during compilation.\n');
end