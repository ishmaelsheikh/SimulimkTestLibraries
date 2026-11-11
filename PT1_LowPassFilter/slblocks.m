function blkStruct = slblocks
% Registers FilterLib in the Simulink Library Browser.
% This folder must be on the MATLAB path.
Browser.Library = 'FilterLib';
Browser.Name    = 'Filter Library';
blkStruct.Browser = Browser;
