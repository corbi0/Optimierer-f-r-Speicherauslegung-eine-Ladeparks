function eur_per_kWh = batt_eur_per_kWh_stufen(E_kWh)
% BATT_EUR_PER_KWH_STUFEN  Stückkosten für BESS mit containerbasierter Stufung.
%
% Diese Funktion bildet die Stückkosten pro kWh für ein
% containerisiertes Batteriespeichersystem auf eine stufenweise konstante
% Preisfunktion ab. Jede Batterieeinheit besitzt einen festen
% Energieinhalt E_unit_MWh und eine Leistung P_unit_MW (z. B. 3 MWh und
% 1.5 MW pro Container). Für eine gewünschte Kapazität E_kWh wird die
% benötigte Anzahl Container aufgerundet. Anschließend werden die
% Gesamtinvestitionskosten über bess_cost_scaler berechnet und durch die
% gewünschte Energiemenge dividiert. Der Rückgabewert sorgt dafür, dass
% ``eur_per_kWh * E_kWh`` unabhängig von der Position im Intervall der
% aktuellen Containerstufe immer dieselben Gesamtkosten ergibt.

    arguments
        E_kWh (1,1) double {mustBePositive}
    end

    % Containergrößen (können bei Bedarf angepasst werden)
    E_unit_MWh = 3.0;      % MWh pro Container
    P_unit_MW  = 1.5;      % MW pro Container
    % Benötigte Containeranzahl (aufgerundet)
    E_total_MWh = E_kWh / 1000;
    n_units = max(1, ceil(E_total_MWh / E_unit_MWh));

    % Parameterstruktur für bess_cost_scaler
    p = struct();
    p.E_unit_MWh = E_unit_MWh;
    p.P_unit_MW  = P_unit_MW;
    p.n_units    = n_units;

    out = bess_cost_scaler(p);
    % Preis pro kWh: so definiert, dass out.capex_total_per_kWh * E_kWh =
    % Gesamt-CAPEX für diese Stufe
    eur_per_kWh = out.capex_total_per_kWh;

end