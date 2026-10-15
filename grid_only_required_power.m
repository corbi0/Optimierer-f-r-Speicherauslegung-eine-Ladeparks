function [P_req_kW, cover_achieved] = grid_only_required_power(site_name, targetCoverFrac, minServeRatio)
% Berechnet den nötigen Netzanschluss P für Grid-only, damit
% die Cover-Bedingung mit (targetCoverFrac, minServeRatio) erreicht wird.
%
% Beispiel:
%   [P_req, cov] = grid_only_required_power("Hochwald_West", 0.95, 0.90)

    if nargin < 3, minServeRatio   = 0.90; end
    if nargin < 2, targetCoverFrac = 0.95; end

    % 1) Lastprofil laden (dein Helper)
    [~, P_load] = build_load_profile(site_name, false);   % kW mittlere 15-min Leistung
    L = max(P_load(:), 0);                                % Sicherheit: keine negativen

    % 2) Erforderliches P berechnen
    if targetCoverFrac >= 1 - eps
        Qf = max(L);
    else
        Qf = quantile(L, targetCoverFrac);
    end
    SAFETY = 1.00;                       % ggf. 1.02 o.ä. wählen
    P_req_kW = SAFETY * (minServeRatio * Qf);

    % 3) Gegencheck: erzielte Cover mit diesem P
    den = max(L, 1e-6);
    sr  = min(P_req_kW ./ den, 1);
    sr(L < 1e-6) = 1;                    % wie in deinem Code
    cover_achieved = mean(sr >= minServeRatio);

    % 4) Ausgabe
    fprintf('Site=%s | targetCoverFrac=%.3f | minServeRatio=%.3f\n', string(site_name), targetCoverFrac, minServeRatio);
    fprintf('=> benötigtes P≈ %.1f kW  | erzielte Cover= %.3f\n', P_req_kW, cover_achieved);
end
