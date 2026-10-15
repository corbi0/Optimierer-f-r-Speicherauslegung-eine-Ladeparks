%% ausfuehrung_ES_mu_lambda_ALT_konstant.m
% Ausführung: (μ,λ)-ES – ALT/konstante Kosten
% - Lastprofil wird EINMAL über build_load_profile(site_name) erzeugt
% - t-Achse in Stunden (0.25-Raster), From-Workspace-Block interpoliert
% - fester Simulink-Schritt dt = 10

%% 0) Schrittweite
dt = 10;  % [s]

%% 1) Standortwahl
% "GoldeneBremm_Sued" | "TecklenburgerLand_West" | "Hochwald_West" | "Inntal_West"
site_name = "Inntal_West";

% EINMAL Lastprofil bauen
[t15, P_15min] = build_load_profile(site_name, false);

% Variablen wie früher bereitstellen
time_day = t15;        % Stunden (0, 0.25, ...)
P_load   = P_15min;    % kW (mittlere 15-min Leistung)

% (Optional) Legacy-Namen für vollständige Kompatibilität:
assignin('base','t15', time_day);
assignin('base','E_scaled_15min', P_load);

%% 1a) Solver/Modelleinstellungen
modelName = 'Battery_PowerEnergy_GridSOC_netz';
if ~bdIsLoaded(modelName), open_system(modelName); end
set_param(modelName, ...
    'SolverType','Fixed-step', ...
    'Solver','ode3', ...
    'FixedStep', num2str(dt), ...
    'StopTime', num2str(time_day(end)), ...   % z.B. 8759.5
    'MaxConsecutiveMinStep','1000');

% Wenn dein From-Workspace-Block zwei getrennte Variablen nutzt:
%   Zeit = 'time_day', Daten = 'P_load', Interpolate = on (inherit).
assignin('base','time_day', time_day);
assignin('base','P_load',   P_load);

%% 2) Standort-Info (nur für Logging)
baseSite  = pick_site_by_name(site_name);

%% 3) Optionen / Startwerte
opts = struct;
opts.E_nom_kWh0      = 10000;   % Start-Batteriegröße
opts.P_grid_max_kW0  = 5000;    % Start-Netzanschluss
opts.E0_kWh          = 2000;    % Startenergie absolut (kWh)

% (nur Info/Konsistenz)
opts.site_name       = site_name;
opts.baseSite        = baseSite;

% *** KONSTANTE KOSTEN (ALT) ***
opts.c_batt          = 100;     % €/kWh konstant
opts.c_grid          = 200;     % €/kW  konstant

% Zielkriterien
opts.targetCoverFrac = 0.95;
opts.minServeRatio   = 0.7;

% ES-Parameter
opts.mode        = 'selfadapt';
opts.sigma0      = [0.01 0.01];
opts.sigmaMinRel = 0.001;
opts.sigmaMaxRel = 0.3;

opts.E_bounds    = [50 1e7];
opts.P_bounds    = [50 1e7];

opts.mu          = 3;
opts.lambda      = 30;
opts.maxGen      = 100;
opts.verbose     = true;
opts.rngSeed     = 1;
opts.costTol     = 1e-2;
opts.coverTol    = 1e-4;
opts.stallGen    = 20;

%% 4) Start Optimierer (ALT: konstante Preise)
res = optimize_battery_grid_ES_mu_lambda_konstanter_preis( ...
          modelName, time_day, P_load, opts);

%% 5) Ergebnis
fprintf('\n=== Global-Best Ergebnis (ALT, konstante Kosten) ===\n');
fprintf('Standort : %s\n', string(site_name));
fprintf('Batterie : %.1f kWh\n', res.best_E_nom_kWh);
fprintf('Netz     : %.1f kW\n',  res.best_P_grid_max_kW);
fprintf('Kosten   : %.1f €\n',   res.best_cost);
fprintf('Cover    : %.3f (feasible=%d)\n', res.best_cover, res.feasible);

%% 6) Verlaufsplots
try
    H = res.history;
    figure('Name','ES-Verlauf (ALT, konstant)','Color','w');
    tiledlayout(2,1,'Padding','compact','TileSpacing','compact');

    nexttile; plot(H.Gen, H.best_cost, '-o'); grid on;
    xlabel('Generation'); ylabel('Kosten [€]');
    title('Bester Kind-Score je Generation (Kosten)');

    nexttile; plot(H.Gen, H.best_cover, '-o'); grid on;
    xlabel('Generation'); ylabel('Cover');
    title('Bester Kind-Score je Generation (Cover)');
catch
    warning('History-Plot übersprungen.');
end

%% ===== Helper =====
function S = pick_site_by_name(name)
    switch string(name)
        case "GoldeneBremm_Sued"
            S = struct('name',"GoldeneBremm_Sued",'kW',1000,'route_m',6066, ...
                'L_auto_m',0,'L_gewaesser_m',90,'L_strasse_m',45,'double_feed',[],'force_voltage_kV',[]);
        case "TecklenburgerLand_West"
            S = struct('name',"TecklenburgerLand_West",'kW',1000,'route_m',4288, ...
                'L_auto_m',0,'L_gewaesser_m',0,'L_strasse_m',15,'double_feed',[],'force_voltage_kV',[]);
        case "Hochwald_West"
            S = struct('name',"Hochwald_West",'kW',1000,'route_m',6055, ...
                'L_auto_m',0,'L_gewaesser_m',0,'L_strasse_m',15,'double_feed',[],'force_voltage_kV',[]);
        case "Inntal_West"
            S = struct('name',"Inntal_West",'kW',1000,'route_m',13322, ...
                'L_auto_m',20,'L_gewaesser_m',75,'L_strasse_m',0,'double_feed',[],'force_voltage_kV',[]);
        otherwise
            error('Unbekannter Standortname: %s', name);
    end
end
