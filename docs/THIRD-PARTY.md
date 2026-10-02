# Drittdaten und Drittdienste

## Herstellerliste für Hardware-Adressen (`Resources/oui.bin`)

Die Datei ordnet den ersten drei Bytes einer Hardware-Adresse (OUI) den Namen des Herstellers
zu. Sie enthält 53 667 Einträge, einen je Zeile (`AABBCC<TAB>Name`), sortiert, roh mit Deflate
komprimiert (`NSData.decompressed(using: .zlib)`).

- **Quelle der Daten:** IEEE Registration Authority, MA-L-Register
  (<https://standards-oui.ieee.org/oui/oui.txt>).
- **Aufbereitung:** die Zusammenstellung des Projekts *oui-data* von silverwind
  (<https://github.com/silverwind/oui-data>), BSD-Lizenz.
- **Lizenz der Aufbereitung (BSD 3-Clause):** Weitergabe in Quell- und Binärform ist mit dem
  Hinweis auf die Urheber erlaubt; der Name der Urheber darf nicht ohne Zustimmung zur Werbung
  verwendet werden. Die Namen der Hersteller selbst sind Marken ihrer Inhaber.
- **Aktualisieren:** Quelle neu laden, nach `AABBCC<TAB>Name` sortieren, mit `zlib` im Modus
  `-15` (rohes Deflate) komprimieren und die Datei ersetzen. Der Test `ouiCompressed` prüft
  Aufbau und Kompression, `ouiLookup` die Suche.
- **Grenzen:** Adressen mit gesetztem „lokal verwaltet“-Bit (Bit 1 des ersten Bytes) haben keinen
  Hersteller, die App sagt „Zufällige Adresse“. MA-M- und MA-S-Blöcke (28 und 36 Bit) stehen
  nicht in der Liste; ein Hersteller mit eigenem kleinen Block erscheint unter dem Namen des
  Registers für den umgebenden 24-Bit-Block.

## Netzbetreiber und Land eines Routers (Team Cymru)

Traceroute und die Abfrage der öffentlichen Adresse stellen Namensabfragen an
`<umgekehrte Adresse>.origin.asn.cymru.com` und `AS<Nummer>.asn.cymru.com` (TXT-Einträge).
Die App sendet sie über den DNS-Server des Netzes; sie fragt nur öffentliche Adressen, nie
private, Loopback-, Link-Local- und Carrier-NAT-Adressen. In der Traceroute lässt sich das
abschalten. Der Dienst ist frei nutzbar; für starke Nutzung nennt Team Cymru eigene Regeln
(<https://www.team-cymru.com/ip-asn-mapping>).

## Öffentliche Adresse (Cloudflare)

Die Abfrage `https://1.1.1.1/cdn-cgi/trace` und `https://[2606:4700:4700::1111]/cdn-cgi/trace`
liefert Adresse, Land und Rechenzentrum, nur auf Knopfdruck.
