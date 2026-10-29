<#
.SYNOPSIS
  Offline Russian voice-over for "Night Shift" via Windows SAPI (System.Speech).

.NOTES
  DO NOT USE THIS SCRIPT TO BUILD THE GAME IN THIS SANDBOX - SAPI cannot render
  to a file here. It is kept as a dependency-free fallback for a normal Windows
  workstation; the shipped voice-over in assets/audio/voice/*.wav was rendered by
  tools/gen_voice_piper.py (offline piper, ru_RU-irina-medium).

  Measured in the DSH sandbox (Windows PowerShell 5.1, process at Low Mandatory
  Level):
    * GetInstalledVoices() does list Microsoft David/Zira/Irina Desktop and the
      HKLM voice tokens are present;
    * SelectVoice('Microsoft Irina Desktop') then throws "No voice installed on
      the system or none available with the current security setting", and the
      COM path (SAPI.SpVoice + SpFileStream + AudioOutputStream + Speak) fails
      with 0x80045040, or 0x80045002 when no explicit format is given;
    * WinRT SpeechSynthesizer.AllVoices raises "Internal Speech Error".
  Use python tools/gen_voice_piper.py [--force] [--only <dialogue_id>] [--dry-run]
  for the real build; this wrapper (tools/gen_voice.py) calls this script.

.DESCRIPTION
  Reads scripts/dialogue/data/voice_manifest.json and renders one WAV per
  dialogue node into assets/audio/voice/<dialogue_id>_<node_id>.wav.

  Synthesis:  voice "Microsoft Irina Desktop" (ru-RU), Rate -1, Volume 100,
              output PCM 16-bit mono 44.1 kHz (SetOutputToWaveFile).
  Post-process: leading/trailing silence is trimmed to at most 120 ms total per
              edge (60 ms head + 120 ms tail of real silence), then the file is
              normalised so the peak is exactly -1 dBFS.

  Existing WAV files are never overwritten unless -Force is passed.

  The script source is ASCII-only on purpose: Windows PowerShell 5.1 reads a
  BOM-less .ps1 as ANSI, and literal Cyrillic in the source would be mangled.
  Russian text is read from the manifest with `Get-Content -Encoding UTF8`.

.PARAMETER Manifest
  Path to voice_manifest.json (default: scripts/dialogue/data/voice_manifest.json).

.PARAMETER OutDir
  Output directory (default: assets/audio/voice).

.PARAMETER LogPath
  Where the per-file report is written (UTF-8).

.PARAMETER Only
  Render only this dialogue id.

.PARAMETER Force
  Overwrite existing WAV files.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\gen_voice.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Manifest = '',
    [string]$OutDir   = '',
    [string]$LogPath  = '',
    [string]$Voice    = 'Microsoft Irina Desktop',
    [int]$Rate        = -1,
    [int]$Volume      = 100,
    [int]$MarginMs    = 120,
    [double]$PeakDbfs = -1.0,
    [string]$Only     = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Defaults are resolved here (not in the param block) so the script also works
# when it is dot-sourced or when $PSScriptRoot is not populated yet.
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) { $scriptRoot = (Get-Location).Path }
if ([string]::IsNullOrEmpty($Manifest)) { $Manifest = Join-Path $scriptRoot '..\scripts\dialogue\data\voice_manifest.json' }
if ([string]::IsNullOrEmpty($OutDir))   { $OutDir   = Join-Path $scriptRoot '..\assets\audio\voice' }
if ([string]::IsNullOrEmpty($LogPath))  { $LogPath  = Join-Path $scriptRoot 'gen_voice.log' }

# --- WAV trimmer / normaliser ----------------------------------------------
# Trim + peak normalisation in C#: looping over millions of samples in pure
# PowerShell would take minutes, compiled code does it in milliseconds.

if (-not ('NsVoiceWav' -as [type])) {
    $wavSrc = @'
using System;
using System.IO;

public static class NsVoiceWav
{
    // Returns "ok dur_ms=<int> peak_db=<x.xx> head_sil_ms=<int> tail_sil_ms=<int>".
    public static string Process(string inPath, string outPath, int marginMs, double peakDbfs, double silenceDbfs)
    {
        byte[] all = File.ReadAllBytes(inPath);
        if (all.Length < 44) throw new Exception("wav too short: " + all.Length);
        if (all[0] != (byte)'R' || all[1] != (byte)'I' || all[2] != (byte)'F' || all[3] != (byte)'F')
            throw new Exception("not a RIFF file");

        int rate = 0, channels = 0, bits = 0, dataOff = -1, dataLen = 0;
        int pos = 12;
        while (pos + 8 <= all.Length)
        {
            string id = new string(new char[] { (char)all[pos], (char)all[pos + 1], (char)all[pos + 2], (char)all[pos + 3] });
            int len = BitConverter.ToInt32(all, pos + 4);
            if (id == "fmt ")
            {
                channels = BitConverter.ToInt16(all, pos + 10);
                rate = BitConverter.ToInt32(all, pos + 12);
                bits = BitConverter.ToInt16(all, pos + 22);
            }
            else if (id == "data")
            {
                dataOff = pos + 8;
                dataLen = len;
                if (dataOff + dataLen > all.Length) dataLen = all.Length - dataOff;
                break;
            }
            pos += 8 + len + (len & 1);
        }
        if (dataOff < 0) throw new Exception("no data chunk");
        if (channels != 1 || bits != 16) throw new Exception("expected mono 16-bit, got channels=" + channels + " bits=" + bits);
        if (rate <= 0) throw new Exception("bad sample rate");

        int n = dataLen / 2;
        short[] s = new short[n];
        Buffer.BlockCopy(all, dataOff, s, 0, n * 2);

        int maxAbs = 0;
        for (int i = 0; i < n; i++)
        {
            int a = s[i] < 0 ? -(int)s[i] : (int)s[i];
            if (a > maxAbs) maxAbs = a;
        }
        if (maxAbs == 0) throw new Exception("only silence");

        double silAmp = 32767.0 * Math.Pow(10.0, silenceDbfs / 20.0);
        int first = 0;
        while (first < n && Math.Abs((int)s[first]) < silAmp) first++;
        int last = n - 1;
        while (last >= 0 && Math.Abs((int)s[last]) < silAmp) last--;
        if (first > last) throw new Exception("only silence");

        int headMargin = (int)Math.Round((double)rate * marginMs / 2000.0);  // 60 ms when margin=120
        int tailMargin = (int)Math.Round((double)rate * marginMs / 1000.0);  // 120 ms when margin=120
        int start = first - headMargin; if (start < 0) start = 0;
        int end = last + tailMargin; if (end > n - 1) end = n - 1;

        double target = Math.Floor(32767.0 * Math.Pow(10.0, peakDbfs / 20.0));
        double gain = target / (double)maxAbs;
        int outN = end - start + 1;
        byte[] body = new byte[outN * 2];
        int peakOut = 0;
        for (int i = 0; i < outN; i++)
        {
            double v = s[start + i] * gain;
            if (v > 32767.0) v = 32767.0;
            if (v < -32768.0) v = -32768.0;
            short q = (short)Math.Round(v);
            int a = q < 0 ? -(int)q : (int)q;
            if (a > peakOut) peakOut = a;
            body[i * 2] = (byte)(q & 0xFF);
            body[i * 2 + 1] = (byte)((q >> 8) & 0xFF);
        }

        using (FileStream fs = new FileStream(outPath, FileMode.Create, FileAccess.Write))
        {
            BinaryWriter w = new BinaryWriter(fs);
            w.Write(new byte[] { (byte)'R', (byte)'I', (byte)'F', (byte)'F' });
            w.Write(36 + outN * 2);
            w.Write(new byte[] { (byte)'W', (byte)'A', (byte)'V', (byte)'E' });
            w.Write(new byte[] { (byte)'f', (byte)'m', (byte)'t', (byte)' ' });
            w.Write(16);
            w.Write((short)1);            // PCM
            w.Write((short)1);            // mono
            w.Write(rate);
            w.Write(rate * 2);            // byte rate
            w.Write((short)2);            // block align
            w.Write((short)16);           // bits per sample
            w.Write(new byte[] { (byte)'d', (byte)'a', (byte)'t', (byte)'a' });
            w.Write(outN * 2);
            w.Write(body);
            w.Flush();
        }

        int durMs = (int)Math.Round(1000.0 * outN / rate);
        double peakDb = 20.0 * Math.Log10(Math.Max(1.0, (double)peakOut) / 32767.0);
        int headSilMs = (int)Math.Round(1000.0 * (first - start) / rate);
        int tailSilMs = (int)Math.Round(1000.0 * (end - last) / rate);
        return string.Format("ok dur_ms={0} peak_db={1:0.00} head_sil_ms={2} tail_sil_ms={3}", durMs, peakDb, headSilMs, tailSilMs);
    }
}
'@
    Add-Type -TypeDefinition $wavSrc -Language CSharp -ErrorAction Stop
}

# System.Speech cannot SelectVoice under the DSH sandbox: the engine reports
# "No voice installed on the system or none available with the current security
# setting" even though the tokens are installed and enumerable. The SAPI 5 COM
# objects (SAPI.SpVoice / SAPI.SpFileStream) work in the same process, so the
# synthesis path uses COM and writes straight into a WAV file stream.
$ErrorActionPreference = 'Stop'

# --- Paths ------------------------------------------------------------------

$manifestFull = [System.IO.Path]::GetFullPath($Manifest)
$outFull = [System.IO.Path]::GetFullPath($OutDir)
$logFull = [System.IO.Path]::GetFullPath($LogPath)

if (-not (Test-Path -LiteralPath $manifestFull)) {
    throw ("manifest not found: " + $manifestFull)
}
if (-not (Test-Path -LiteralPath $outFull)) {
    New-Item -ItemType Directory -Force -Path $outFull | Out-Null
}

# --- Manifest ---------------------------------------------------------------

$raw = Get-Content -LiteralPath $manifestFull -Encoding UTF8 -Raw
if ([string]::IsNullOrWhiteSpace($raw)) { throw ("manifest is empty: " + $manifestFull) }
$data = $raw | ConvertFrom-Json

# --- Speech engine ----------------------------------------------------------

$synth = New-Object -ComObject SAPI.SpVoice
$installed = @($synth.GetVoices() | ForEach-Object { $_.GetDescription() })
$voiceToken = $null
foreach ($candidate in $synth.GetVoices()) {
    $desc = $candidate.GetDescription()
    if ($desc -like ($Voice + '*') -or $desc -eq $Voice) { $voiceToken = $candidate; $voiceDesc = $desc; break }
}
if ($null -eq $voiceToken) {
    throw ("voice not installed: '" + $Voice + "' (available: " + ($installed -join ', ') + ")")
}
$synth.Voice = $voiceToken
$synth.Rate = $Rate
$synth.Volume = $Volume

# --- Render -----------------------------------------------------------------

$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add(("voice=" + $Voice + " rate=" + $Rate + " volume=" + $Volume + " margin_ms=" + $MarginMs + " peak_dbfs=" + $PeakDbfs + " force=" + [bool]$Force))
$created = 0
$skipped = 0
$noText = 0
$failed = 0
$totalMs = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($dialogueProp in $data.PSObject.Properties) {
    $dialogueId = $dialogueProp.Name
    if ($dialogueId.StartsWith('_')) { continue }
    if ($Only -ne '' -and $dialogueId -ne $Only) { continue }
    $nodes = $dialogueProp.Value
    if ($null -eq $nodes) { continue }

    foreach ($nodeProp in $nodes.PSObject.Properties) {
        $nodeId = $nodeProp.Name
        if ($nodeId.StartsWith('_')) { continue }
        $entry = $nodeProp.Value
        $text = ''
        if ($null -ne $entry -and $null -ne $entry.PSObject.Properties['text']) {
            $text = [string]$entry.text
        }
        $fileName = $dialogueId + '_' + $nodeId + '.wav'
        $finalPath = Join-Path $outFull $fileName

        if ($text -notmatch '\p{L}') {
            $lines.Add("SKIP_NO_TEXT " + $dialogueId + "/" + $nodeId + " :: text has no pronounceable letters")
            $noText++
            continue
        }
        if ((Test-Path -LiteralPath $finalPath) -and -not $Force) {
            $lines.Add("SKIP_EXISTS " + $fileName)
            $skipped++
            continue
        }

        $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) ('nsvoice_' + [guid]::NewGuid().ToString('N') + '.wav')
        $stream = $null
        try {
            $stream = New-Object -ComObject SAPI.SpFileStream
            # 30 = SAFT44kHz16BitMono, 3 = SSFMCreateForWrite
            $stream.Format.Type = 30
            $stream.Open($tmpPath, 3, $false)
            $synth.AudioOutputStream = $stream
            $synth.Speak($text)
            $stream.Close()
            $info = [NsVoiceWav]::Process($tmpPath, $finalPath, $MarginMs, $PeakDbfs, -50.0)
            $created++
            $lines.Add("OK " + $fileName + " " + $info)
            $m = [regex]::Match($info, 'dur_ms=(\d+)')
            if ($m.Success) { $totalMs += [int]$m.Groups[1].Value }
        }
        catch {
            $failed++
            $lines.Add("FAIL " + $fileName + " :: " + $_.Exception.Message)
            if (Test-Path -LiteralPath $finalPath) {
                try { Remove-Item -LiteralPath $finalPath -Force } catch { }
            }
        }
        finally {
            if ($null -ne $stream) {
                try { $stream.Close() } catch { }
                try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream) } catch { }
            }
            if (Test-Path -LiteralPath $tmpPath) {
                try { Remove-Item -LiteralPath $tmpPath -Force } catch { }
            }
        }
    }
}

try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($synth) } catch { }
$sw.Stop()

$lines.Add(("SUMMARY created=" + $created + " skipped=" + $skipped + " no_text=" + $noText + " failed=" + $failed + " total_ms=" + $totalMs + " elapsed_s=" + [math]::Round($sw.Elapsed.TotalSeconds, 1)))

foreach ($line in $lines) { Write-Output $line }
$lines -join "`r`n" | Set-Content -LiteralPath $logFull -Encoding UTF8

if ($failed -gt 0) { exit 1 }
exit 0
