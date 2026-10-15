%% Ausführung: (μ,λ)-ES mit Cover-Bewertung auf Profilraster

% --- 0) Sicheres dt setzen (deterministische Simulation) ---
if ~exist('dt','var') || isempty(dt)
    dt = 10;  % [s] fester Integrationsschritt
end

% === Standort wählen (nur Name ändern) ===
site_name = "Inntal_West";   % "GoldeneBremm_Sued"|"TecklenburgerLand_West"|"Hochwald_West"|"Inntal_West"
baseSite  = pick_site_by_name(site_name);

priceLib = []; % oder deine eigene Preisbibliothek

% EINMAL Lastprofil bauen
[t15, P_15min] = build_load_profile(site_name, false);


time_day = t15;            % Zeitachse deines 15-min-Profils
P_load   = P_15min; % kW

% --- 1a) Solver auf Fixed-step setzen ---
modelName = 'Battery_PowerEnergy_GridSOC_netz';
if ~bdIsLoaded(modelName), open_system(modelName); end
set_param(modelName, ...
    'SolverType','Fixed-step', ...
    'Solver','ode3', ...              % oder 'discrete', wenn alles diskret
    'FixedStep', num2str(dt), ...
    'MaxConsecutiveMinStep','1000');

% --- 2) Optionen / Startwerte ---
opts = struct;
opts.E_nom_kWh0      = 10000;   % Start-Batteriegröße
opts.P_grid_max_kW0  = 5000;   % Start-Netzanschluss
opts.E0_kWh          = 2000;    % Startenergie absolut (kWh)


% €/kW = f(P): holt EUR_per_kW_withBKZ aus ev_costs_single_model_v5
opts.c_grid = @(P_kW) grid_eur_per_kW(P_kW, baseSite, priceLib);

% €/kWh = f(E): nutzt AUSSCHLIESSLICH Defaults aus bess_cost_scaler.m
% (keine Parameter hier in der Ausführung setzen!)
opts.c_batt = @(E_kWh) batt_eur_per_kWh_from_scaler(E_kWh);

% Zielkriterien
opts.targetCoverFrac = 0.95;
opts.minServeRatio   = 0.90;

% ES-Parameter
opts.mode        = 'selfadapt';
opts.sigma0      = [0.03 0.03];
opts.sigmaMinRel = 0.001;
opts.sigmaMaxRel = 0.6;

opts.E_bounds    = [50 1e7];
opts.P_bounds    = [50 1e7];

opts.mu          = 3;
opts.lambda      = 20;
opts.maxGen      = 100;
opts.verbose     = true;
opts.rngSeed     = 1;
opts.costTol     = 1e-2;
opts.coverTol    = 1e-4;
opts.stallGen    = 20;

% --- 3) Start Optimierer ---
res = optimize_battery_grid_ES_mu_lambda_preisfunktion(modelName, time_day, P_load, opts);

% --- 4) Ergebnis ---
fprintf('\n=== Global-Best Ergebnis ===\n');
fprintf('Standort: %s\n', string(site_name));
fprintf('Batterie: %.1f kWh\n', res.best_E_nom_kWh);
fprintf('Netz    : %.1f kW\n',  res.best_P_grid_max_kW);
fprintf('Kosten  : %.1f €\n',   res.best_cost);
fprintf('Cover   : %.3f (feasible=%d)\n', res.best_cover, res.feasible);

% --- 5) Verlaufsplots ---
try
    H = res.history;
    figure('Name','ES-Verlauf','Color','w');
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

% --- 6) Kosten-Breakdown-Plot (Netz A–D + Batterie CAPEX) ---
try
    % Netz-Kosten für bestes P
    Sbest     = baseSite; 
    Sbest.kW  = res.best_P_grid_max_kW;
    Rbest     = ev_costs_single_model_v6(Sbest, priceLib, 'verbose', false);
    grid_parts   = [Rbest.A, Rbest.B, Rbest.C, Rbest.D];  % A–D
    grid_labels  = {'A Trasse/Kabel','B Station/Trafo','C DSO-Abgang','D BKZ'};

    % Batterie-Kosten konsistent zu opts.c_batt (nutzt bess_cost_scaler-DEFAULTS!)
    bout = bess_costs_from_E(res.best_E_nom_kWh);  % nutzt nur Defaults aus bess_cost_scaler
    batt_parts  = [bout.capex_breakdown.DC, bout.capex_breakdown.PCS, ...
                   bout.capex_breakdown.BOS, bout.capex_breakdown.EPC, ...
                   bout.capex_breakdown.SOFT, bout.capex_breakdown.SITE];
    batt_labels = {'DC (Batterie)','PCS','BOS','EPC','SOFT','SITE'};

    % Plot
    figure('Name','Kosten-Zusammensetzung','Color','w');
    data = [grid_parts; batt_parts];      % 2 x N
    bar(data, 'stacked'); grid on;
    xticklabels({'Netz (A–D)','Batterie'});
    ylabel('Kosten [€]');
    title(sprintf('Kosten-Zusammensetzung | %s | P*=%.0f kW, E*=%.0f kWh', ...
           string(site_name), res.best_P_grid_max_kW, res.best_E_nom_kWh));
    legend([grid_labels, batt_labels], 'Location','bestoutside');

    % Totals als Text
    y = [sum(grid_parts), sum(batt_parts)];
    for i=1:numel(y)
        text(i, y(i)*1.02, sprintf('%.0f €', y(i)), ...
             'HorizontalAlignment','center','FontWeight','bold');
    end

    % Spezifische Kosten
    fprintf('\n--- Spezifische Kosten ---\n');
    fprintf('Netz:  %.1f €/kW (inkl. BKZ)\n', Rbest.EUR_per_kW_withBKZ);
    fprintf('Batt:  %.1f €/kWh (gesamt CAPEX)\n', bout.capex_total_per_kWh);
catch ME
    warning('Breakdown-Plot fehlgeschlagen: %s', ME.message);
end


%% ================= Lokale Helper-Funktionen (immer ans Ende!) =================

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

function eur_per_kw = grid_eur_per_kW(P_kW, baseSite, priceLib)
    % Kein Cache während wir debuggen (damit Änderungen IMMER ankommen)
    S = baseSite; S.kW = P_kW;
    R = ev_costs_single_model_v6(S, priceLib, 'verbose', false);
    eur_per_kw = R.EUR_per_kW_withBKZ;
    % Debug: ins Base schreiben
    assignin('base','DBG_grid_last',R);
end

function eur_per_kWh = batt_eur_per_kWh_from_scaler(E_kWh)
    % Nutzt ausschließlich die DEFAULTS aus bess_cost_scaler.m
    % => Wenn du dort price_floor_per_kWh/Basis änderst, wirkt das hier sofort.
    E_unit_MWh  = 5.64;
    P_unit_MW   = E_unit_MWh/4;         % 4h-System
    E_total_MWh = E_kWh/1000;
    n_units     = max(1, ceil(E_total_MWh / E_unit_MWh));

    p = struct();
    p.E_unit_MWh = E_unit_MWh;
    p.P_unit_MW  = P_unit_MW;
    p.n_units    = n_units;

    out = bess_cost_scaler(p);
    % Nutze den Gesamt-CAPEX je kWh (realistischer für Systemkosten)
    eur_per_kWh = out.capex_total_per_kWh;

    % Debug: Breakdown in Base, damit du siehst, WAS reinläuft
    assignin('base','DBG_batt_last_out', out);
end

function bout = bess_costs_from_E(E_kWh)
    % Für den Breakdown-Plot – identisch zu batt_eur_per_kWh_from_scaler()
    E_unit_MWh  = 5.64;
    P_unit_MW   = E_unit_MWh/4;
    E_total_MWh = E_kWh/1000;
    n_units     = max(1, ceil(E_total_MWh / E_unit_MWh));

    p = struct();
    p.E_unit_MWh = E_unit_MWh;
    p.P_unit_MW  = P_unit_MW;
    p.n_units    = n_units;

    bout = bess_cost_scaler(p);
end
