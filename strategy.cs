// Logica de decisao do bot. Usada tanto pelo bot.ps1 (ao vivo) quanto pelo
// backtest.ps1 (historico), para que os dois se comportem exatamente igual.
// Compilada pelo PowerShell 5.1 (Add-Type), entao usa apenas sintaxe C# 5.
using System;
using System.Collections.Generic;

public class DipStrategy
{
    // Parametros (percentuais ja divididos por 100; tempos em minutos)
    public double WindowMin = 15;    // janela para achar o topo recente
    public double WarmupMin = 5;     // historico minimo antes de comprar
    public double Dip = 0.006;       // queda abaixo do topo para comprar
    public double TakeProfit = 0.008;// alta sobre a entrada para vender (ou armar o trailing)
    public double StopLoss = 0.02;   // queda sobre a entrada para vender no prejuizo; 0 = sem stop
    public double CooldownMin = 10;  // pausa depois de um stop
    public double TrendMin = 0;      // media movel (EMA) de tendencia; 0 = desligado
    public double Trail = 0;         // trailing: depois de atingir TakeProfit, vende ao cair isso do pico; 0 = desligado

    // Estado
    public bool InPosition;
    public double Entry;
    public double Peak;
    public DateTime PauseUntil = DateTime.MinValue;
    public double Ema;
    public string Reason = "";

    private bool emaReady;
    private DateTime emaT;
    private DateTime firstT = DateTime.MinValue;
    // Deque monotonica: guarda candidatos a maximo da janela em O(1) amortizado
    private LinkedList<KeyValuePair<DateTime, double>> maxq = new LinkedList<KeyValuePair<DateTime, double>>();

    public double WindowTop { get { return maxq.Count > 0 ? maxq.First.Value.Value : 0; } }
    public bool TrendOk(double mid) { return TrendMin <= 0 || (emaReady && mid >= Ema); }

    // Alimenta um preco sem tomar decisao (usado para pre-carregar historico).
    public void Feed(DateTime t, double mid)
    {
        if (firstT == DateTime.MinValue) firstT = t;
        while (maxq.Count > 0 && maxq.Last.Value.Value <= mid) maxq.RemoveLast();
        maxq.AddLast(new KeyValuePair<DateTime, double>(t, mid));
        DateTime cutoff = t.AddMinutes(-WindowMin);
        while (maxq.First.Value.Key < cutoff) maxq.RemoveFirst();

        if (TrendMin > 0)
        {
            if (!emaReady) { Ema = mid; emaT = t; emaReady = true; }
            else
            {
                double dt = (t - emaT).TotalMinutes;
                if (dt > 0) { Ema += (1 - Math.Exp(-dt / TrendMin)) * (mid - Ema); emaT = t; }
            }
        }
    }

    // Retorna "BUY", "SELL" ou "" (nada). Em SELL, Reason diz o motivo.
    public string OnTick(DateTime t, double bid, double ask)
    {
        double mid = (bid + ask) / 2;
        Feed(t, mid);
        Reason = "";

        if (InPosition)
        {
            if (bid > Peak) Peak = bid;
            if (StopLoss > 0 && bid <= Entry * (1 - StopLoss)) { Reason = "stop"; return "SELL"; }
            if (Trail <= 0)
            {
                if (bid >= Entry * (1 + TakeProfit)) { Reason = "lucro"; return "SELL"; }
            }
            else if (Peak >= Entry * (1 + TakeProfit) && bid <= Peak * (1 - Trail))
            {
                Reason = "lucro"; return "SELL";
            }
            return "";
        }

        if ((t - firstT).TotalMinutes < WarmupMin) return "";
        if (t < PauseUntil) return "";
        if (!TrendOk(mid)) return "";
        if (ask <= WindowTop * (1 - Dip)) return "BUY";
        return "";
    }

    public void Bought(double price) { InPosition = true; Entry = price; Peak = price; }

    public void Sold(DateTime t, bool wasStop)
    {
        InPosition = false;
        if (wasStop) PauseUntil = t.AddMinutes(CooldownMin);
    }
}
