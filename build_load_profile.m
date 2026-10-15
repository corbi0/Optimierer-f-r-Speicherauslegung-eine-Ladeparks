function [t15, P_15min] = build_load_profile(site_name, doPlot)
% Baut 15-min-Lastprofil aus stündlichen Daten, einmalig pro Standort.
% t15   : Zeitvektor in Stunden (0, 0.25, 0.5, ...)
% P_15min: Leistung [kW] je 15 min
% Cache: vermeidet Wiederholungsarbeit in derselben MATLAB-Session.

    if nargin < 2, doPlot = false; end

    % -------- Cache ----------
    persistent CACHE
    key = char(string(site_name));
    if ~isempty(CACHE) && isfield(CACHE, key)
        t15     = CACHE.(key).t15;
        P_15min = CACHE.(key).P_15min;
        if doPlot, local_plot(t15, P_15min); end
        return
    end

    % -------- 1) Stündliche Daten robust laden ----------
    [E_hourly, srcInfo] = load_hourly(site_name);
    E_hourly = E_hourly(:);  % Spaltenvektor

    % -------- 2) 96-Punkte Tagesform (sum=1) ----------
    Shape_Norm = [
        0.01613;0.01569;0.01544;0.01521;0.01486;0.01476;0.01448;0.01410;
        0.01397;0.01355;0.01276;0.01224;0.01169;0.01102;0.01055;0.00980;
        0.00891;0.00838;0.00802;0.00748;0.00669;0.00611;0.00554;0.00503;
        0.00454;0.00384;0.00338;0.00311;0.00249;0.00219;0.00192;0.00169;
        0.00159;0.00219;0.00250;0.00250;0.00287;0.00385;0.00535;0.00637;
        0.00790;0.01083;0.01252;0.01363;0.01433;0.01335;0.01273;0.01171;
        0.01119;0.01048;0.01013;0.00971;0.00933;0.00897;0.00873;0.00848;
        0.00816;0.00786;0.00745;0.00713;0.00708;0.00699;0.00713;0.00710;
        0.00681;0.00702;0.00736;0.00780;0.00833;0.00857;0.00893;0.00951;
        0.00991;0.01053;0.01175;0.01256;0.01321;0.01537;0.01628;0.01730;
        0.01863;0.01853;0.01786;0.01697;0.01660;0.01670;0.01666;0.01649;
        0.01671;0.01679;0.01703;0.01695;0.01706;0.01680;0.01670;0.01659];
    Shape_Norm = Shape_Norm / sum(Shape_Norm);

    % -------- 3) 15-min Profil bauen ----------
    nHoursPerDay = 24;
    nSlots = 96;      % 15 min pro Tag
    dt_h   = 0.25;    % 15 min in Stunden

    nDays  = floor(numel(E_hourly)/nHoursPerDay);
    if nDays < 1
        error('build_load_profile: zu wenige Stundenwerte (%d) in %s.', numel(E_hourly), srcInfo);
    end

    E_hourly = E_hourly(1:nDays*nHoursPerDay);
    E_daily  = sum(reshape(E_hourly, nHoursPerDay, nDays), 1)';  % kWh/Tag

    P_15min = zeros(nDays*nSlots,1);   % kW je 15 min
    for d = 1:nDays
        idx = (d-1)*nSlots + (1:nSlots);
        energy_15min_kWh = Shape_Norm * E_daily(d);  % kWh je 15 min
        P_15min(idx)     = energy_15min_kWh / dt_h;  % -> kW
    end

    % Zeitachse in Stunden (0, 0.25, 0.5, ...)
    t15 = (0:numel(P_15min)-1)' * dt_h;

    % -------- Cache füllen ----------
    CACHE.(key) = struct('t15',t15,'P_15min',P_15min);

    % Optional plotten
    if doPlot, local_plot(t15, P_15min); end
end

function [E_hourly, srcInfo] = load_hourly(site_name)
% Robustes Laden:
% - probiert mehrere Dateinamen-Varianten
% - nimmt korrekten Variablennamen, oder auto-detektiert den ersten
%   numerischen Vektor, dessen Länge ein Vielfaches von 24 ist.

    site = string(site_name);

    % Kandidaten (Datei, Variablenname(n))
    switch site
        case "Inntal_West"
            files = {"Inntal_West.mat"};
            vars  = {"Inntal_West","InntalWest"};
        case "GoldeneBremm_Sued"
            files = {"GoldeneBremm_Sued.mat","Goldene_Bremm_S_d.mat","GoldeneBremm_Sued_.mat"};
            vars  = {"GoldeneBremm_Sued","Goldene_Bremm_S_d","GoldeneBremmSued"};
        case "TecklenburgerLand_West"
            files = {"TecklenburgerLand_West.mat","Tecklenburger_Land_West.mat"};
            vars  = {"TecklenburgerLand_West","Tecklenburger_Land_West","TecklenburgerLandWest"};
        case "Hochwald_West"
            files = {"Hochwald_West.mat"};
            vars  = {"Hochwald_West","HochwaldWest"};
        otherwise
            error('Unbekannter Standortname: %s', site);
    end

    lastErr = "";
    for f = 1:numel(files)
        fn = files{f};
        if exist(fn,'file') ~= 2
            lastErr = sprintf('Datei nicht gefunden: %s', fn);
            continue
        end
        S = load(fn);
        % 1) bevorzugte Variablennamen testen
        for v = 1:numel(vars)
            vn = vars{v};
            if isfield(S, vn) && isnumeric(S.(vn)) && isvector(S.(vn))
                E_hourly = S.(vn)(:);
                srcInfo  = sprintf('%s::%s', fn, vn);
                return
            end
        end
        % 2) Auto-Detektion: erster numerischer Vektor mit Länge % 24 == 0
        fns = fieldnames(S);
        for v = 1:numel(fns)
            cand = S.(fns{v});
            if isnumeric(cand) && isvector(cand) && mod(numel(cand),24)==0
                E_hourly = cand(:);
                srcInfo  = sprintf('%s::%s (auto)', fn, fns{v});
                return
            end
        end
        lastErr = sprintf('In %s keine passende Variable gefunden.', fn);
    end

    error('build_load_profile: Konnte %s nicht laden. Letzte Meldung: %s', string(site_name), lastErr);
end

function local_plot(t15, P)
    figure('Color','w'); 
    N = min(numel(P), 7*96);
    plot(t15(1:N), P(1:N), 'LineWidth',1.2); grid on;
    xlabel('Zeit [h]'); ylabel('Leistung [kW]');
    title('15-min Lastprofil (erste 7 Tage)');
end
