import Foundation

extension PhotoSetExporter {

    /// What is in the bundle, what the numbers mean, and how to get them into the four
    /// programs people actually use.
    ///
    /// Written out in words rather than claiming compatibility, because a definition the
    /// reader can check is worth more than a promise they cannot.
    func readme(selection: Selection, scene: SceneBundleExporter.Scene,
                images: [WrittenImage], options: PhotoSetOptions) -> String {
        let posed = scene.poseSource == .arkitVIO
        let baselines = selection.frames.map(\.baseline).filter(\.isFinite).sorted()
        let medianBaseline = baselines.isEmpty ? Double.nan : baselines[baselines.count / 2]

        var text = """
        Sensorstorm — Bilder für Fotogrammetrie

        \(images.count) Bilder in images/, ausgewählt aus \(selection.candidateCount)
        geprüften Videobildern in \(selection.windowCount) Abschnitten.

        Diese App baut kein 3D-Modell, und aus einem Video kann das auch sonst niemand.
        Was hier liegt, ist der Rohstoff dafür: scharfe, räumlich verteilte Bilder mit
        bekannter Brennweite\(posed ? ", bekannter Position und bekannter Blickrichtung" : " und bekannter Position").
        Das Modell entsteht in RealityScan, Metashape, Meshroom oder COLMAP.


        """

        if posed {
            text += """
            AUSWAHL

            Ein Bild wird behalten, wenn die Kamera sich seit dem letzten behaltenen Bild um
            mindestens \(fmt(options.subject.baselineMetres)) m bewegt oder um mindestens
            \(fmt(options.subject.rotationRadians * 180 / .pi))° gedreht hat. Innerhalb jedes
            Abschnitts gewinnt das schärfste Bild.

            Der Mindestabstand ist eine Annahme über die Entfernung zum Objekt — die misst
            diese Aufnahme nicht. Gewählt war: \(options.subject.rawValue).
            Erreichter Medianabstand: \(fmt(medianBaseline)) m.

            \(selection.rejectedTooClose) Bilder wurden verworfen, weil die Kamera sich nicht
            weit genug bewegt hatte. Wer stehen bleibt, bekommt ein Bild, nicht hundert
            gleiche — das ist Absicht.


            """
        } else {
            text += """
            OHNE KAMERAPOSE

            Diese Aufnahme lief nicht im ARKit-Modus, es gibt also keine gemessene
            Blickrichtung. Enthalten sind geotaggte Einzelbilder mit echten Intrinsics:
            die Software rechnet die Posen selbst aus, der GPS-Ort beschleunigt das und
            georeferenziert das Ergebnis.

            Für Posen als Startwert die nächste Aufnahme im Fotogrammetrie-Modus (ARKit)
            machen. Die Bilder wurden nach Zeit verteilt statt nach Kamerabewegung, weil
            eine aus GPS integrierte Weglänge integriertes Rauschen ist.


            """
        }

        text += """
        DATEIEN

        images/NNNN_fMMMMMM.jpg   NNNN ist die laufende Nummer, MMMMMM das Videobild.
                                 Alphabetisch sortiert ist zeitlich sortiert.
        \(PhotoSetCSV.fileName)              eine Zeile pro Bild, siehe unten
        colmap/                  cameras.txt, points3D.txt\(posed ? ", images.txt" : " (ohne images.txt: keine Posen)")
        track.gpx                der GPS-Track der Aufnahme, falls vorhanden
        metadata.json            Gerät, Ströme, Zeitbasis der Aufnahme

        EXIF IN JEDEM BILD

        FocalLengthIn35mmFilm    fx · 36 / längere Bildkante. Die physische Sensorgrösse
                                 ist unbekannt und wird nicht geraten; FocalLength in
                                 Millimetern steht deshalb bewusst nicht drin.
        GPSLatitude/Longitude    WGS84
        GPSAltitude              orthometrisch (über Meer), nicht ellipsoidisch — so ist
                                 EXIF definiert. Die ellipsoidische Höhe steht in
                                 \(PhotoSetCSV.fileName) als alt_ellipsoidal daneben.
        DateTimeOriginal         UTC. Die Aufnahme speichert keine Zeitzone, und die des
                                 exportierenden Rechners wäre eine falsche Angabe.
        Orientation              immer 1. Das Video wird ohne Transform geschrieben, damit
                                 die Intrinsics die gespeicherten Pixel beschreiben. Ein
                                 hochkant gefilmtes Bild sieht deshalb gekippt aus. Bitte
                                 nicht "korrigieren" — cx/cy würden dann nicht mehr passen.

        WINKEL IN \(PhotoSetCSV.fileName.uppercased())

        yaw    Grad im Uhrzeigersinn von geografisch Nord: 0 = Nord, 90 = Ost.
        pitch  Grad über dem Horizont; negativ blickt nach unten.
        roll   Grad, positiv wenn die rechte Bildkante nach oben kippt.
        qx..qw Quaternion, Reihenfolge xyzw, dreht kameralokale Vektoren in die Welt.
               Kameralokal: −Z ist die Blickrichtung, +Y ist oben, +X ist rechts.

        Positionen stehen doppelt, und sie sind unterschiedlich genau:
          x_enu/y_enu/z_enu   Meter Ost/Nord/Hoch ab dem Anker. \(posed ? "Aus der ARKit-Odometrie, in sich auf Zentimeter konsistent." : "Aus GPS.")
          lat/lon/alt_msl     WGS84, erbt die Genauigkeit des GPS — Meter.
          e_lv95/n_lv95       Schweizer Landeskoordinaten (EPSG:2056).
        \(posed ? "Beiden dieselbe Prior-Genauigkeit zu geben verschenkt die bessere.\n" : "")

        IMPORT

        RealityScan / RealityCapture
          1. images/ als Ordner hinzufügen.
          2. Alignment → Import → Trajectory (in älteren Versionen "Flight Log") auf
             \(PhotoSetCSV.fileName). Beim Spaltenformat name, x, y, z zuordnen — entweder
             lat/lon/alt_msl mit EPSG:4326 oder e_lv95/n_lv95/h_lv95 mit EPSG:2056.
          3. Prior-Genauigkeit nach dem Absatz oben setzen, dann Align.

        Agisoft Metashape
          1. Add Photos auf images/.
          2. Reference → Import auf \(PhotoSetCSV.fileName), Komma als Trennzeichen,
             Kopfzeile ja, Label = name.
          3. Align Photos, Reference preselection: Source.

        Meshroom
          images/ importieren — die Brennweite kommt aus dem EXIF von allein. Für bekannte
          Posen den Umweg über colmap/ nehmen; wie der Knoten dafür in deiner Version
          heisst, ändert sich zwischen Releases, bitte dort nachsehen.

        COLMAP
          colmap/ ist ein Modellordner mit bekannten Posen. Nach dem Feature-Matching
          point_triangulator mit --input_path colmap. Die Bild-IDs in der Datenbank müssen
          zu images.txt passen.

        """
        return text
    }

    private func fmt(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.2f", value)
    }
}
