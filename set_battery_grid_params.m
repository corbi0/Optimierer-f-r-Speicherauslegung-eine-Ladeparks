%% set_params_and_save.m
% Dieses Skript setzt NUR Parameter im Model Workspace und speichert das Modell.
% Keine Simulation, kein Logging, keine Blockänderungen.

%% ======= KONFIGURATION (hier anpassen) =======
modelName        = 'Battery_PowerEnergy_GridSOC_netz';  % Name deiner .slx

% Basisparameter
E_nom_kWh        = 62040;     % Batteriegröße [kWh]
P_grid_max_kW    = 72000;     % Netzanschluss [kW]
eta_c            = 0.96;    % Wirkungsgrad Laden
eta_d            = 0.96;    % Wirkungsgrad Entladen
SOC0             = 0.00;    % Start-SOC (0..1), leer lassen mit []

% SOC-Tabellen (lasse leer, wenn du vorhandene im Modell behalten willst)
useFineSOC       = true;    % auf 1%-Raster bringen (pchip)
soc_bp_in        = [0 0.1 0.3 0.5 0.8 0.9 1.0];  % leer [] wenn nicht überschreiben
Cc_tab_in        = [1.5 2 2.5 2 1 0.8 0.5];  % Laden  [1/h], leer [] wenn nicht überschreiben
Cd_tab_in        = [0.8 1 2 3 4 4 4];  % Entladen[1/h], leer [] wenn nicht überschreiben

%% ======= AB HIER NICHTS ÄNDERN =======
% Modell laden
if ~bdIsLoaded(modelName), open_system(modelName); end
mdlW = get_param(modelName,'ModelWorkspace');

% Helper
setMW = @(name,val) assignin(mdlW,name,val);

% Basisparameter setzen (nur wenn nicht leer)
if ~isempty(E_nom_kWh),     setMW('E_nom',      E_nom_kWh);     end
if ~isempty(P_grid_max_kW), setMW('P_grid_max', P_grid_max_kW); end
if ~isempty(eta_c),         setMW('eta_c',      eta_c);         end
if ~isempty(eta_d),         setMW('eta_d',      eta_d);         end

% SOC-Tabellen optional setzen
if ~isempty(soc_bp_in) && ~isempty(Cc_tab_in) && ~isempty(Cd_tab_in)
    soc_bp = soc_bp_in(:).';
    Cc_tab = Cc_tab_in(:).';
    Cd_tab = Cd_tab_in(:).';

    if useFineSOC
        soc_new = 0:0.01:1;                           % 1%-Raster
        Cc_tab  = interp1(soc_bp, Cc_tab, soc_new, 'pchip');
        Cd_tab  = interp1(soc_bp, Cd_tab, soc_new, 'pchip');
        soc_bp  = soc_new;
    end
    % Randbedingungen erzwingen
    if ~isempty(Cc_tab), Cc_tab(end) = 0; end         % Laden bei SOC=1 -> 0
    if ~isempty(Cd_tab), Cd_tab(1)   = 0; end         % Entladen bei SOC=0 -> 0

    setMW('soc_bp', soc_bp);
    setMW('Cc_tab', Cc_tab);
    setMW('Cd_tab', Cd_tab);
end

% Start-SOC als Integrator-InitialCondition (in kWh)
if ~isempty(SOC0)
    try
        E_nom  = evalin(mdlW,'E_nom');                % [kWh]
        E0_kWh = max(0,min(1,SOC0)) * E_nom;
        set_param([modelName '/Int_Energy'], 'InitialCondition', num2str(E0_kWh));
    catch ME
        warning('Start-SOC konnte nicht gesetzt werden: %s', ME.message);
    end
end

% Speichern
save_system(modelName);
disp('✅ Parameter gesetzt und Modell gespeichert. Jetzt dein Run-Skript starten.');
