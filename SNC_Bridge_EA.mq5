SMC Bridge EA
 · MQ5
//+------------------------------------------------------------------+
//|  SMC_Bridge_EA.mq5                                               |
//|  Menerima sinyal SMC Analyzer (ntfy, ditandatangani SHA-256)     |
//|  lalu mengeksekusi di MT5 (Finex).                               |
//|                                                                  |
//|  SETUP WAJIB:                                                    |
//|  Tools > Options > Expert Advisors > centang                     |
//|    "Allow WebRequest for listed URL" dan tambahkan               |
//|    https://ntfy.sh                                               |
//|  Tombol "Algo Trading" di toolbar MT5 harus hijau.               |
//|                                                                  |
//|  DEFAULT AMAN: InpEnableTrading=false (dry-run, hanya log)       |
//|                InpAllowReal=false (akun REAL diblokir)           |
//+------------------------------------------------------------------+
#property copyright "SMC Bridge"
#property version   "1.00"
#property strict
 
#include <Trade\Trade.mqh>
 
//--- koneksi
input string InpServer   = "https://ntfy.sh"; // Server ntfy
input string InpTopic    = "";                // Topic ntfy KHUSUS bridge (acak, panjang)
input string InpSecret   = "";                // Secret bersama (min 12 karakter, sama dgn aplikasi)
input int    InpPollSec  = 2;                 // Interval polling (detik)
input int    InpMaxSigAgeSec = 120;           // Sinyal lebih tua dari ini ditolak
 
//--- eksekusi
input bool   InpEnableTrading = false;        // false = DRY-RUN (tidak kirim order)
input bool   InpAllowReal     = false;        // izinkan akun REAL (harus true utk akun live)
input double InpLot           = 0.01;         // Lot tetap
input long   InpMagic         = 26112501;     // Magic number
input int    InpPendingExpireMin = 90;        // Order limit kedaluwarsa (menit)
input int    InpMarketTolPts  = 150;          // Toleransi market fill dari entry (points)
input int    InpDeviationPts  = 30;           // Slippage maksimum (points)
 
//--- proteksi
input int    InpMaxPositions  = 1;            // Maks posisi + pending (magic ini)
input int    InpMaxSpreadPts  = 60;           // Spread maks (points). XAU 2 digit: 60 = $0.60
input double InpMinRR         = 1.5;          // R:R minimum ke TP
input double InpMaxRiskPctEq  = 30.0;         // Rugi jika SL kena maks % equity
input double InpMaxDailyLossPct = 30.0;       // Stop entry baru jika equity turun % dari awal hari
 
CTrade   trade;
datetime g_since   = 0;
bool     g_halt    = false;
string   g_lastMsg = "-";
int      g_ok=0, g_rej=0;
 
//+------------------------------------------------------------------+
string Sha256Hex(const string s)
{
   char d[], k[], r[];
   int n = StringToCharArray(s, d, 0, StringLen(s), CP_UTF8);
   ArrayResize(d, n);
   ArrayResize(k, 0);
   if(CryptEncode(CRYPT_HASH_SHA256, d, k, r) <= 0) return "";
   string h = "";
   for(int i = 0; i < ArraySize(r); i++) h += StringFormat("%02x", (uchar)r[i]);
   return h;
}
//+------------------------------------------------------------------+
string ExtractStr(const string line, const string key)
{
   int p = StringFind(line, key);
   if(p < 0) return "";
   p += StringLen(key);
   int q = StringFind(line, "\"", p);
   if(q < 0) return "";
   return StringSubstr(line, p, q - p);
}
long ExtractNum(const string line, const string key)
{
   int p = StringFind(line, key);
   if(p < 0) return 0;
   p += StringLen(key);
   string s = "";
   while(p < StringLen(line))
   {
      ushort c = StringGetCharacter(line, p);
      if(c < '0' || c > '9') break;
      s += ShortToString(c);
      p++;
   }
   return (long)StringToInteger(s);
}
//+------------------------------------------------------------------+
void Log(const string m)
{
   g_lastMsg = TimeToString(TimeLocal(), TIME_SECONDS) + " " + m;
   Print("[SMCB] ", m);
   Comment("SMC Bridge EA\n",
           "Mode: ", (InpEnableTrading ? "LIVE ORDER" : "DRY-RUN"), "\n",
           "Akun: ", (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL ? "REAL" : "DEMO/CONTEST"),
           " #", (string)AccountInfoInteger(ACCOUNT_LOGIN), "\n",
           "Diterima OK: ", g_ok, " | Ditolak: ", g_rej, g_halt ? " | HALT harian" : "", "\n",
           "Terakhir: ", g_lastMsg);
}
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpTopic) < 8 || StringLen(InpSecret) < 12)
   {
      Alert("SMC Bridge: isi InpTopic (min 8) dan InpSecret (min 12 karakter).");
      return INIT_PARAMETERS_INCORRECT;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPts);
   g_since = TimeGMT() - InpMaxSigAgeSec;
   EventSetTimer(MathMax(1, InpPollSec));
   Log("started. trading=" + (InpEnableTrading ? "ON" : "dry-run") +
       " real_allowed=" + (InpAllowReal ? "yes" : "no"));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
//+------------------------------------------------------------------+
void OnTimer()
{
   CheckDailyLoss();
   Poll();
}
//+------------------------------------------------------------------+
void CheckDailyLoss()
{
   MqlDateTime t; TimeToStruct(TimeGMT(), t);
   string gv = StringFormat("SMCB_DAYEQ_%04d%02d%02d_%I64d", t.year, t.mon, t.day, AccountInfoInteger(ACCOUNT_LOGIN));
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!GlobalVariableCheck(gv)) GlobalVariableSet(gv, eq);
   double start = GlobalVariableGet(gv);
   bool h = (start > 0 && eq <= start * (1.0 - InpMaxDailyLossPct / 100.0));
   if(h && !g_halt) Log("HALT: batas rugi harian tercapai (equity " + DoubleToString(eq, 2) + " dari " + DoubleToString(start, 2) + ")");
   g_halt = h;
}
//+------------------------------------------------------------------+
void Poll()
{
   string url = InpServer + "/" + InpTopic + "/json?poll=1&since=" + IntegerToString((long)g_since);
   char post[], res[];
   string rh;
   ArrayResize(post, 0);
   ResetLastError();
   int code = WebRequest("GET", url, "", 5000, post, res, rh);
   if(code == -1)
   {
      Log("WebRequest gagal err=" + IntegerToString(GetLastError()) + " (tambahkan https://ntfy.sh di Tools>Options>Expert Advisors)");
      return;
   }
   if(code != 200) { Log("HTTP " + IntegerToString(code)); return; }
 
   string body = CharArrayToString(res, 0, -1, CP_UTF8);
   string lines[];
   int n = StringSplit(body, '\n', lines);
   long maxT = 0;
   for(int i = 0; i < n; i++)
   {
      string ln = lines[i];
      if(StringFind(ln, "\"event\":\"message\"") < 0) continue;
      long tm = ExtractNum(ln, "\"time\":");
      if(tm > maxT) maxT = tm;
      string msg = ExtractStr(ln, "\"message\":\"");
      if(StringLen(msg) > 0) Handle(msg);
   }
   if(maxT > 0) g_since = (datetime)maxT;
}
//+------------------------------------------------------------------+
// Format: SMCB1|id|sym|dir|entry|sl|tp|tf|kind|t|sig
void Handle(const string msg)
{
   string p[];
   if(StringSplit(msg, '|', p) != 11 || p[0] != "SMCB1") return;
   string id = p[1], sym = p[2], dir = p[3], sE = p[4], sS = p[5], sT = p[6], tf = p[7], kind = p[8];
   long t = (long)StringToInteger(p[9]);
 
   string payload = InpSecret + "|" + id + "|" + sym + "|" + dir + "|" + sE + "|" + sS + "|" + sT + "|" + tf + "|" + kind + "|" + p[9];
   if(Sha256Hex(payload) != p[10]) { g_rej++; Log("TOLAK: signature salah (secret beda / pesan palsu)"); return; }
 
   string gv = "SMCB_ID_" + id;
   if(GlobalVariableCheck(gv)) return;            // sudah diproses
   GlobalVariableSet(gv, (double)TimeGMT());
 
   long age = (long)TimeGMT() - t;
   if(age > InpMaxSigAgeSec || age < -30) { g_rej++; Log("TOLAK " + sym + ": sinyal kadaluarsa (" + IntegerToString(age) + " dtk)"); return; }
 
   if(kind == "PING") { g_ok++; Log("PING OK dari aplikasi (latency ~" + IntegerToString(age) + " dtk)"); return; }
 
   Execute(sym, dir, StringToDouble(sE), StringToDouble(sS), StringToDouble(sT), tf, kind, id);
}
//+------------------------------------------------------------------+
int CountMine()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   { ulong tk = PositionGetTicket(i); if(tk > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic) c++; }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   { ulong tk = OrderGetTicket(i); if(tk > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic) c++; }
   return c;
}
bool HasSymbol(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   { ulong tk = PositionGetTicket(i); if(tk > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == sym) return true; }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   { ulong tk = OrderGetTicket(i); if(tk > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic && OrderGetString(ORDER_SYMBOL) == sym) return true; }
   return false;
}
void Reject(const string sym, const string why) { g_rej++; Log("TOLAK " + sym + ": " + why); }
//+------------------------------------------------------------------+
void Execute(const string sym, const string dir, double entry, double sl, double tp,
             const string tf, const string kind, const string id)
{
   bool buy = (dir == "BUY");
   if(!buy && dir != "SELL") { Reject(sym, "arah tidak valid"); return; }
   if(!SymbolSelect(sym, true)) { Reject(sym, "simbol tidak ada di broker (cek symbol map)"); return; }
 
   int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK), bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || pt <= 0) { Reject(sym, "harga belum tersedia"); return; }
 
   entry = NormalizeDouble(entry, dg); sl = NormalizeDouble(sl, dg); tp = NormalizeDouble(tp, dg);
   if(sl <= 0 || tp <= 0 || entry <= 0) { Reject(sym, "entry/SL/TP kosong (SL wajib)"); return; }
   if(buy  && !(sl < entry && entry < tp)) { Reject(sym, "geometri BUY salah"); return; }
   if(!buy && !(tp < entry && entry < sl)) { Reject(sym, "geometri SELL salah"); return; }
 
   // proteksi akun
   bool real = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
   if(real && !InpAllowReal) { Reject(sym, "akun REAL tapi InpAllowReal=false"); return; }
   if(g_halt) { Reject(sym, "HALT batas rugi harian"); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) { Reject(sym, "Algo Trading mati di terminal/EA"); return; }
   if(CountMine() >= InpMaxPositions) { Reject(sym, "batas posisi/pending tercapai"); return; }
   if(HasSymbol(sym)) { Reject(sym, "sudah ada posisi/pending di simbol ini"); return; }
 
   double spr = (ask - bid) / pt;
   if(spr > InpMaxSpreadPts) { Reject(sym, "spread " + DoubleToString(spr, 0) + " pts > batas"); return; }
 
   double stopsDist = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   double price = buy ? ask : bid;
 
   // pilih jenis order
   ENUM_ORDER_TYPE ot;
   bool pending = false;
   double use = entry;
   if(buy)
   {
      if(ask - entry >= stopsDist && ask - entry > 0)       { ot = ORDER_TYPE_BUY_LIMIT;  pending = true; }
      else if(ask > sl + stopsDist && ask <= entry + InpMarketTolPts * pt) { ot = ORDER_TYPE_BUY;  use = ask; }
      else { Reject(sym, "harga sudah lewat zona entry"); return; }
   }
   else
   {
      if(entry - bid >= stopsDist && entry - bid > 0)       { ot = ORDER_TYPE_SELL_LIMIT; pending = true; }
      else if(bid < sl - stopsDist && bid >= entry - InpMarketTolPts * pt) { ot = ORDER_TYPE_SELL; use = bid; }
      else { Reject(sym, "harga sudah lewat zona entry"); return; }
   }
 
   double risk = MathAbs(use - sl), rew = MathAbs(tp - use);
   if(risk <= 0 || rew / risk < InpMinRR) { Reject(sym, "R:R " + DoubleToString(risk > 0 ? rew / risk : 0, 2) + " < " + DoubleToString(InpMinRR, 2)); return; }
   if(MathAbs(sl - use) < stopsDist || MathAbs(tp - use) < stopsDist) { Reject(sym, "SL/TP terlalu dekat (stops level)"); return; }
 
   // lot
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), vst = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double lot = MathMax(vmin, MathMin(vmax, MathFloor(InpLot / vst + 1e-9) * vst));
   lot = NormalizeDouble(lot, 2);
 
   // rugi maksimum & margin
   ENUM_ORDER_TYPE mt = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double pl = 0, mg = 0;
   if(!OrderCalcProfit(mt, sym, lot, use, sl, pl)) { Reject(sym, "gagal hitung risiko"); return; }
   double loss = -pl, eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(loss > eq * InpMaxRiskPctEq / 100.0)
   { Reject(sym, "rugi jika SL $" + DoubleToString(loss, 2) + " > " + DoubleToString(InpMaxRiskPctEq, 0) + "% equity ($" + DoubleToString(eq, 2) + ")"); return; }
   if(!OrderCalcMargin(mt, sym, lot, use, mg) || mg > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8)
   { Reject(sym, "margin tidak cukup (butuh $" + DoubleToString(mg, 2) + ")"); return; }
 
   string cm = StringSubstr("SMCB " + kind + " " + tf, 0, 31);
   string desc = StringFormat("%s %s %s lot=%.2f entry=%s SL=%s TP=%s risk=$%.2f RR=%.2f",
                              (pending ? "LIMIT" : "MARKET"), dir, sym, lot,
                              DoubleToString(use, dg), DoubleToString(sl, dg), DoubleToString(tp, dg), loss, rew / risk);
 
   if(!InpEnableTrading) { g_ok++; Log("DRY-RUN (tidak dikirim): " + desc); return; }
 
   trade.SetTypeFillingBySymbol(sym);
   bool ok;
   if(pending)
   {
      datetime exp = TimeCurrent() + InpPendingExpireMin * 60;
      ok = buy ? trade.BuyLimit(lot, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, exp, cm)
               : trade.SellLimit(lot, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, exp, cm);
   }
   else
      ok = buy ? trade.Buy(lot, sym, 0, sl, tp, cm) : trade.Sell(lot, sym, 0, sl, tp, cm);
 
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
   { g_ok++; Log("ORDER OK: " + desc + " ticket=" + (string)trade.ResultOrder()); }
   else
   { g_rej++; Log("ORDER GAGAL ret=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription() + " | " + desc); }
}
//+------------------------------------------------------------------+
