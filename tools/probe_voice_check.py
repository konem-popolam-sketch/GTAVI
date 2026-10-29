import wave, audioop, os
for name in ["mila_mila_01.wav","kostya_kostya_06.wav","voice_voice_05.wav"]:
    path = os.path.join("assets","audio","voice",name)
    with wave.open(path,"rb") as w:
        frames, rate, ch, width = w.getnframes(), w.getframerate(), w.getnchannels(), w.getsampwidth()
        data = w.readframes(frames)
    dur = frames/float(rate)
    peak = audioop.max(data, width)
    rms = audioop.rms(data, width)
    # speech-like activity: share of 20ms windows above 5% of peak
    step = int(rate*0.02)*width*ch
    loud = sum(1 for i in range(0,len(data)-step,step) if audioop.rms(data[i:i+step], width) > peak*0.05)
    total = max(1, len(data)//step)
    print(f"{name}: {dur:.2f}s {rate}Hz {ch}ch {width*8}bit peak={peak} rms={rms} active={100*loud/total:.0f}%")
