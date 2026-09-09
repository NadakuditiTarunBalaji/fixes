function verify_teamtools_files()
%VERIFY_TEAMTOOLS_FILES Check that all required files exist and parse correctly.

    folder = fileparts(mfilename('fullpath'));
    if isempty(folder), folder = pwd; end
    
    requiredFiles = { ...
        'teamtools.m', ...
        'buildParentModelCore.m', ...
        'extractAttributesCore.m', ...
        'arrangeModelLayout.m', ...
        'listModelConnections.m', ...
        'insertUnitDelayOnBranch.m', ...
        'configureSubsystemSignals.m', ...
        'getSubsystemPorts.m', ...
        'convert_m_to_sldd.m'};
    
    fprintf('Checking folder: %s\n\n', folder);
    allOK = true;
    
    for i = 1:numel(requiredFiles)
        f = requiredFiles{i};
        fullPath = fullfile(folder, f);
        if ~isfile(fullPath)
            fprintf('  [MISSING] %s\n', f);
            allOK = false;
        else
            % Verify the file parses without syntax errors
            try
                checkcode(fullPath);
                fprintf('  [OK]      %s\n', f);
            catch
                fprintf('  [SYNTAX]  %s (has syntax errors)\n', f);
                allOK = false;
            end
        end
    end
    
    fprintf('\n');
    if allOK
        fprintf('All files present and valid.\n');
    else
        fprintf('Fix the issues above before running teamtools.\n');
    end
end