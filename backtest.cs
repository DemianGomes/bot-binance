// Motor de backtest: roda a DipStrategy sobre candles de 1 minuto.
// Cada candle vira 4 "ticks" (abertura, minima/maxima, maxima/minima, fechamento)
// para simular o movimento dentro do minuto.
using System;
using System.Collections.Generic;
using System.Threading.Tasks;

public class BtParams
{
    public double WindowMin, Dip, TakeProfit, StopLoss, TrendMin, Trail, CooldownMin = 10, WarmupMin = 5;
    public override string ToString()
    {
        return string.Format(System.Globalization.CultureInfo.InvariantCulture,
            "janela={0}min queda={1:0.##}% lucro={2:0.##}% stop={3:0.##}% tendencia={4}min trailing={5:0.##}%",
            WindowMin, Dip * 100, TakeProfit * 100, StopLoss * 100, TrendMin, Trail * 100);
    }
}

public class BtResult
{
    public BtParams P;
    public double FinalEquity, ReturnPct, MaxDrawdownPct, DaysToTarget = -1, Days;
    public int Trades, Wins, Stops;
}

public static class Backtester
{
    public static BtResult Run(BtParams p, long[] t, double[] o, double[] h, double[] l, double[] c,
                               int from, int to, double fee, double halfSpread, double cash, double target)
    {
        DipStrategy s = new DipStrategy();
        s.WindowMin = p.WindowMin; s.Dip = p.Dip; s.TakeProfit = p.TakeProfit; s.StopLoss = p.StopLoss;
        s.TrendMin = p.TrendMin; s.Trail = p.Trail; s.CooldownMin = p.CooldownMin; s.WarmupMin = p.WarmupMin;

        BtResult r = new BtResult(); r.P = p;
        double start = cash, qty = 0, peakEq = cash, maxDd = 0;
        DateTime epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        DateTime t0 = epoch.AddMilliseconds(t[from]);
        double[] px = new double[4];

        for (int i = from; i < to; i++)
        {
            DateTime ct = epoch.AddMilliseconds(t[i]);
            px[0] = o[i];
            if (c[i] >= o[i]) { px[1] = l[i]; px[2] = h[i]; } else { px[1] = h[i]; px[2] = l[i]; }
            px[3] = c[i];
            for (int k = 0; k < 4; k++)
            {
                DateTime tt = ct.AddSeconds(15 * k);
                double bid = px[k] * (1 - halfSpread), ask = px[k] * (1 + halfSpread);
                string a = s.OnTick(tt, bid, ask);
                if (a == "BUY")
                {
                    qty = cash / ask * (1 - fee); cash = 0; s.Bought(ask);
                }
                else if (a == "SELL")
                {
                    bool stop = s.Reason == "stop";
                    double got = qty * bid * (1 - fee);
                    if (bid > s.Entry) r.Wins++;
                    if (stop) r.Stops++;
                    r.Trades++;
                    cash = got; qty = 0; s.Sold(tt, stop);
                }
            }
            double eq = cash + qty * c[i] * (1 - halfSpread);
            if (eq > peakEq) peakEq = eq;
            double dd = (peakEq - eq) / peakEq;
            if (dd > maxDd) maxDd = dd;
            if (r.DaysToTarget < 0 && eq >= target) r.DaysToTarget = (ct - t0).TotalDays;
        }
        r.FinalEquity = cash + qty * c[to - 1] * (1 - halfSpread);
        r.ReturnPct = (r.FinalEquity / start - 1) * 100;
        r.MaxDrawdownPct = maxDd * 100;
        r.Days = (epoch.AddMilliseconds(t[to - 1]) - t0).TotalDays;
        return r;
    }

    public static BtResult[] RunMany(BtParams[] ps, long[] t, double[] o, double[] h, double[] l, double[] c,
                                     int from, int to, double fee, double halfSpread, double cash, double target)
    {
        BtResult[] res = new BtResult[ps.Length];
        Parallel.For(0, ps.Length, delegate (int i)
        {
            res[i] = Run(ps[i], t, o, h, l, c, from, to, fee, halfSpread, cash, target);
        });
        return res;
    }
}
