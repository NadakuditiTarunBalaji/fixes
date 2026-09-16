function setup_teamtools_large_test()
% SETUP_TEAMTOOLS_LARGE_TEST Creates a complex 10-model environment with mixed
% sample times and matching parameter source files to test teamtools.

    testDir = fullfile(pwd, 'teamtools_large_test_workspace');
    if isfolder(testDir)
        try
            rmdir(testDir, 's');
        catch
            error('Close all open models and files, then run this script again.');
        end
    end
    mkdir(testDir);
    
    fprintf('=== Setting up teamtools 10-Model Test Workspace ===\n');
    fprintf('Target Directory: %s\n\n', testDir);

    % Define our 10 distinct models with different discrete sample rates.
    % The Greatest Common Divisor (GCD) of these rates is exactly 0.001s (1ms).
    modelConfig = struct(...
        'Name', { ...
            'SensorHub', ...       % Model 1: Fast sensor acquisition
            'FastFilter', ...      % Model 2: Signal processing
            'VibeMonitor', ...     % Model 3: Engine vibration analytics
            'EngineController', ...% Model 4: Core controller
            'GearSelector', ...    % Model 5: Shift scheduler
            'ThermalManager', ...  % Model 6: Radiator/Cooling loops
            'CabinComfort', ...    % Model 7: Climate controller
            'DiagnosticsUnit', ... % Model 8: System health and logging
            'DriverDisplay', ...   % Model 9: Display refresh rates
            'ActuatorDriver' ...   % Model 10: Low-level driver outputs
        }, ...
        'Ts', { ...
            '0.001', ... % 1ms
            '0.002', ... % 2ms
            '0.005', ... % 5ms
            '0.010', ... % 10ms
            '0.010', ... % 10ms
            '0.020', ... % 20ms
            '0.050', ... % 50ms
            '0.100', ... % 100ms
            '-1', ...    % Inherited (Runs at rate of connected signals)
            '0.005'  ... % 5ms
        }, ...
        'Inport', { ...
            'raw_voltage', 'raw_speed', 'vibe_accel', 'pedal_pos', 'shift_cmd', ...
            'coolant_temp', 'set_temp', 'error_bus', 'display_bus', 'duty_cycle' ...
        }, ...
        'Outport', { ...
            'raw_speed', 'vibe_accel', 'pedal_pos', 'shift_cmd', 'coolant_temp', ...
            'set_temp', 'error_bus', 'display_bus', 'duty_cycle', 'pwm_out' ...
        }...
    );

    % --- 1. Programmatically Generate the 10 Simulink Models ---
    for i = 1:numel(modelConfig)
        m = modelConfig(i);
        fprintf('Generating Model %d/10: %-20s (Ts = %5s)... ', i, m.Name, m.Ts);
        
        try
            if bdIsLoaded(m.Name)
                close_system(m.Name, 0);
            end
            new_system(m.Name);
            
            % Set discrete fixed-step solver configuration
            set_param(m.Name, 'SolverType', 'Fixed-step', ...
                              'Solver', 'FixedStepDiscrete', ...
                              'FixedStep', m.Ts);
            
            % Add Inport & Outport, then wire them together
            add_block('simulink/Ports & Subsystems/Inport', [m.Name '/' m.Inport], 'Position', [40 50 70 70]);
            add_block('simulink/Ports & Subsystems/Outport', [m.Name '/' m.Outport], 'Position', [200 50 230 70]);
            add_line(m.Name, [m.Inport '/1'], [m.Outport '/1']);
            
            save_system(m.Name, fullfile(testDir, [m.Name '.slx']));
            close_system(m.Name);
            fprintf('Success.\n');
        catch err
            fprintf(2, 'FAILED: %s\n', err.message);
        end
    end

    % --- 2. Create the Excel Ordered Import List (ModelOrder_Large.xlsx) ---
    fprintf('\nGenerating Excel Ordered Model List... ');
    % Order of models in Column A matches signal flow
    orderedNames = {
        'SensorHub';
        'FastFilter';
        'VibeMonitor';
        'EngineController';
        'GearSelector';
        'ThermalManager';
        'CabinComfort';
        'DiagnosticsUnit';
        'DriverDisplay';
        'ActuatorDriver'
    };
    
    excelTable = table(orderedNames, 'VariableNames', {'ModelName'});
    writetable(excelTable, fullfile(testDir, 'ModelOrder_Large.xlsx'));
    fprintf('Done.\n');

    % --- 3. Create Corresponding Parameter .m Files (for Extraction) ---
    fprintf('Generating diagnostic parameter source .m files... ');
    
    % Generate parameter specifications matching the ports of our 10 models
    parameterData = {
        'raw_voltage', 'DataType = ''single'';\nraw_voltage.Min = 0;\nraw_voltage.Max = 5;';
        'raw_speed',   'DataType = ''single'';\nraw_speed.Min = 0;\nraw_speed.Max = 280;';
        'vibe_accel',  'DataType = ''double'';\nvibe_accel.Description = ''Accelerometer G-Forces'';';
        'pedal_pos',   'DataType = ''uint8'';\npedal_pos.Min = 0;\npedal_pos.Max = 100;';
        'shift_cmd',   'DataType = ''Enum_Gear'';\nshift_cmd.Description = ''Active Gear Command'';';
        'coolant_temp','DataType = ''single'';\ncoolant_temp.Min = -40;\ncoolant_temp.Max = 150;';
        'set_temp',    'DataType = ''single'';\nset_temp.Value = 22.0;';
        'error_bus',   'DataType = ''Bus: ErrorBus'';';
        'display_bus', 'DataType = ''Bus: UI_DisplayBus'';';
        'duty_cycle',  'DataType = ''single'';\nduty_cycle.Min = 0;\nduty_cycle.Max = 1;';
        'pwm_out',     'DataType = ''single'';\npwm_out.Description = ''Solenoid Gate Pulse width modulation'';'
    };

    for idx = 1:size(parameterData, 1)
        varName = parameterData{idx, 1};
        codeBody = parameterData{idx, 2};
        
        fileName = fullfile(testDir, ['spec_' varName '.m']);
        fid = fopen(fileName, 'wt');
        if fid ~= -1
            fprintf(fid, '%% Parameter file for: %s\n', varName);
            % Print properties line-by-line matching legacy spec format
            lines = strsplit(codeBody, '\n');
            for l = 1:numel(lines)
                fprintf(fid, '%s.%s\n', varName, lines{l});
            end
            fclose(fid);
        end
    end
    fprintf('Done.\n\n');
    fprintf('=== Large Test Workspace Ready! ===\n');
    fprintf('Run "teamtools" to begin the test sequence.\n');
end