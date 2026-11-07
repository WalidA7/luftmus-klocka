# 😎 Luftmus för Apple Watch

Styr musen på en Windows-dator med handleden. Klockan skickar råa rörelser
(gyro, gravitation, acceleration), tryck och Digital Crown över Wi-Fi till
datorn. All logik (kalibrering, fart, utjämning, paus) körs på datorn.

- `Watch/` – klockappen (SwiftUI + CoreMotion)
- `iOS/` – iPhone-skal som bär klockappen
- `.github/workflows/build.yml` – bygger en osignerad `Luftmus.ipa` på en Mac i molnet

Installera: ladda ner `Luftmus.ipa` från senaste bygget och installera med
Sideloadly (gratis Apple-ID, gäller 7 dagar).
