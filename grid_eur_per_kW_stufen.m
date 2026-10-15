function eur_per_kw = grid_eur_per_kW_stufen(P_kW, baseSite, priceLib)
% GRID_EUR_PER_KW_STUFEN  Kosten pro kW für den Netzanschluss mit Trafostufung.
%
% Diese Funktion berechnet eine stufenweise konstante Preisfunktion für
% den Netzanschluss. Anstatt die Kosten linear mit der angefragten
% Anschlussleistung P_kW zu skalieren, wird die nächsthöhere
% Transformatorgröße (inkl. N‑1‑Redundanz für große Leistungen) gewählt
% und auf dieser Basis das gesamte Netzanschlussprojekt kalkuliert.
% Der Rückgabewert ist so definiert, dass ``eur_per_kw * P_kW`` den
% Gesamtpreis liefert. Somit sind die Kosten in jedem Intervall bis zur
% nächsten Trafostufe konstant.
%
% Inputs
%   P_kW     – gewünschte Anschlussleistung in kW
%   baseSite – Struktur mit Standortparametern (Trassenlängen etc.)
%   priceLib – Preisbibliothek (evtl. leer für Defaults)
%
% Output
%   eur_per_kw – spez. Kosten [€/kW]; multipliziert mit P_kW ergibt die
%                Gesamtkosten des Netzanschlusses

    arguments
        P_kW (1,1) double {mustBePositive}
        baseSite (1,1) struct
        priceLib (1,1) struct = defaultPriceLib()
    end

    %% Trafo-Auswahl
    % Für kleine Leistungen (<7.5 MW) wird die einfache Auswahl ohne N‑1
    % Redundanz verwendet. Ab 7.5 MW muss ein N‑1‑fähiges Set aus mindestens
    % zwei Transformatoren gefunden werden. Die nachgebildeten Funktionen
    % entsprechen den Versionen aus ev_costs_single_model_v6.
    n1_threshold_kW = 7500;
    trafo_lib = priceLib.trafo_lib;
    if P_kW >= n1_threshold_kW
        trafo_set = pick_transformers_n1_stufen(P_kW, trafo_lib, 1.0, 2);
    else
        trafo_set = pick_transformers_simple_stufen(P_kW, trafo_lib);
    end

    % Gesamte installierte MVA in kW
    step_kW = sum([trafo_set.S]) * 1e3;
    % Standortstruktur kopieren und die Anschlussleistung auf die Stufe setzen
    S = baseSite;
    S.kW = step_kW;
    % Gesamtkosten für diese Leistung berechnen
    R = ev_costs_single_model_v6(S, priceLib, 'verbose', false);
    total_cost = R.Total_withBKZ;
    % Spezifische Kosten: so definiert, dass cost = eur_per_kw * P_kW = total_cost
    eur_per_kw = total_cost / P_kW;

end

%% --- Lokale Hilfsfunktionen ---
function trafo_set = pick_transformers_simple_stufen(total_kW, trafo_lib)
% PICK_TRANSFORMERS_SIMPLE_STUFEN  Transformatorauswahl ohne N‑1
%   Repliziert die Logik aus ev_costs_single_model_v6: für eine
%   geforderte Gesamtleistung (kW) wird das wirtschaftlich günstigste
%   Set aus 4 MVA, 6.3 MVA und 10 MVA Transformatoren gewählt, dessen
%   Gesamtkapazität >= total_kW/1000 MW ist. Der Vergleich erfolgt über
%   die Kosten pro MVA der Trafo-Modelle.

    P = total_kW/1000; % in MW
    cpm = arrayfun(@(t) t.price/t.S, trafo_lib);
    [~,ord] = sort(cpm,'ascend');
    need = P;
    chosen = [];
    for k = 1:numel(ord)
        t = trafo_lib(ord(k));
        n = floor(need / t.S);
        if need > 0 && n == 0
            n = 1;
        end
        chosen = [chosen, repmat(t,1,n)];
        need = need - n * t.S;
        if need <= 0
            break;
        end
    end
    if need > 0
        % Noch Restleistung: größtes Modell zusätzlich
        [~,imax] = max([trafo_lib.S]);
        chosen = [chosen, trafo_lib(imax)];
    end
    trafo_set = chosen;
end

function trafo_set = pick_transformers_n1_stufen(total_kW, trafo_lib, n1_fraction, min_trafos)
% PICK_TRANSFORMERS_N1_STUFEN  Transformatorauswahl mit N‑1 Redundanz
%   Sucht die kostengünstigste Kombination von Transformatoren, bei der
%   (a) die Gesamtleistung >= total_kW/1000 MW und
%   (b) die verbleibende Leistung nach Ausfall des größten Transformators
%       mindestens n1_fraction * (total_kW/1000) erreicht. Es werden
%   höchstens 8 Geräte in bis zu drei Größen berücksichtigt. Falls keine
%   gültige Kombination gefunden wird, wird auf die einfache Auswahl
%   zurückgegriffen und ggf. mit weiteren Geräten aufgefüllt.

    P = total_kW/1000; % in MW
    bestCost = inf;
    bestSet = [];
    maxUnits = 8;
    for n1 = 0:maxUnits
        for n2 = 0:maxUnits
            for n3 = 0:maxUnits
                if n1 + n2 + n3 == 0
                    continue;
                end
                % Zusammenstellung erzeugen
                set = [repmat(trafo_lib(1),1,n1), repmat(trafo_lib(2),1,n2), repmat(trafo_lib(3),1,n3)];
                if numel(set) < min_trafos
                    continue;
                end
                totalS = sum([set.S]);
                if totalS < P
                    continue;
                end
                % N‑1 Prüfbedingung: nach Ausfall des größten Trafos
                [~,imax] = max([set.S]);
                remaining = totalS - set(imax).S;
                if remaining < n1_fraction * P
                    continue;
                end
                cost = sum([set.price]);
                if cost < bestCost
                    bestCost = cost;
                    bestSet = set;
                end
            end
        end
    end
    if isempty(bestSet)
        % Fallback: einfache Auswahl wie oben
        bestSet = pick_transformers_simple_stufen(total_kW, trafo_lib);
        while numel(bestSet) < min_trafos
            [~,imax] = max([trafo_lib.S]);
            bestSet = [bestSet, trafo_lib(imax)];
        end
    end
    trafo_set = bestSet;
end

function p = defaultPriceLib()
% DEFAULTPRICELIB  Rückfall auf Standardwerte aus ev_costs_single_model_v6
    p = struct();
    p.trench.regular_per_m = 200;
    p.trench.autobahn.offset  = 20000; p.trench.autobahn.per_m  = 200;
    p.trench.gewaesser.offset = 50000; p.trench.gewaesser.per_m = 300;
    p.trench.strasse.offset   = 10000; p.trench.strasse.per_m   = 180;

    p.material.schutzrohr_per_m = 46.30;
    p.material.ms_joint_per_pc  = 289.91;
    p.material.ms_end_per_pc    = 162.39;

    p.station.per_station_base     = 50000;
    p.station.per_field            = 20000;
    p.station.earthing             = 50000;
    p.station.testing              = 45000;
    p.station.engineering_per_MW   = 15000;
    p.station.ehouse               = 300000;

    p.trafo_lib = [ ...
        struct('S',4.0, 'price',230000); ...
        struct('S',6.3, 'price',350000); ...
        struct('S',10.0,'price',500000) ...
    ];

    p.nshv.base_2trafos     = 200000;
    p.nshv.per_extra_trafo  = 0;

    p.dso.abgang_per_field  = 120000;
    p.dso.bkz_per_kw        = 110;
end