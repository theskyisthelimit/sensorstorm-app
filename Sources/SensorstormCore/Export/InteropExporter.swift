import Foundation

/// Export formats that exist to plug into somebody else's tool rather than to be read here.
///
/// Two of them, for two different reasons. Gyroflow wants a gyro log so it can stabilise the
/// video *afterwards* — which is the only way to have stabilisation at all, since stabilising
/// during capture would decouple the image from the IMU and quietly invalidate every
/// correlation the app exists to make. Sensor Logger's CSV layout is the de-facto schema a
/// whole ecosystem of Python notebooks and converters already reads; matching it means those
/// tools work on Sensorstorm recordings without anyone writing a line of glue.
public enum InteropExporter {

    // MARK: - Gyroflow

    /// Gyroflow's `.gcsv` v1.3: a small header block, then `t,gx,gy,gz,ax,ay,az`.
    ///
    /// `tscale`/`ascale`/`gscale` tell Gyroflow how to read the columns, so the samples
    /// themselves stay in the units they were recorded in — no lossy pre-conversion.
    /// Timestamps are integers in `tscale` units; microseconds keep 400 Hz exact.
    public static func gcsv(gyroscope: StreamReader,
                            accelerometer: StreamReader?,
                            metadata: RecordingMetadata) -> String {
        var out = """
        GYROFLOW IMU LOG
        version,1.3
        id,sensorstorm
        orientation,YxZ
        note,\(metadata.device.model) \(metadata.name)
        tscale,0.000001
        gscale,1.0
        ascale,1.0
        t,gx,gy,gz,ax,ay,az

        """
        out.reserveCapacity(gyroscope.sampleCount * 64)

        // Accelerometer samples arrive on their own schedule; each gyro row takes the last
        // acceleration in effect at its timestamp rather than an interpolated one, because
        // Gyroflow only uses the accelerometer for horizon levelling.
        gyroscope.forEachSample { hostTime, gyro in
            let micros = Int64(((hostTime - metadata.startHostTime) * 1_000_000).rounded())
            let accel = accelerometer?.sample(atOrBefore: hostTime) ?? [0, 0, 0]
            out += "\(micros)"
            for value in gyro.prefix(3) { out += ",\(field(value))" }
            for value in accel.prefix(3) { out += ",\(field(value))" }
            out += "\n"
        }
        return out
    }

    // MARK: - Sensor Logger

    /// Sensor Logger's per-sensor CSV: `time` in epoch nanoseconds, `seconds_elapsed`, then
    /// the channels.
    ///
    /// Nanosecond integers rather than seconds because that is what the community's parsers
    /// expect — `pandas.to_datetime(df.time)` reads them directly, and a float would lose the
    /// resolution the shared clock was built to preserve.
    public static func sensorLoggerCSV(reader: StreamReader, stream: StreamInfo,
                                       metadata: RecordingMetadata) -> String {
        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        var out = "time,seconds_elapsed," + stream.channels.joined(separator: ",") + "\n"
        out.reserveCapacity(reader.sampleCount * 64)

        reader.forEachSample { hostTime, values in
            let elapsed = hostTime - metadata.startHostTime
            let nanoseconds = Int64(((epochAtStart + elapsed) * 1_000_000_000).rounded())
            out += "\(nanoseconds),\(field(elapsed))"
            for value in values { out += ",\(field(value))" }
            out += "\n"
        }
        return out
    }

    /// The name Sensor Logger gives each stream, so its own tooling recognises the file.
    /// Streams it has no equivalent for keep the Sensorstorm name — a converter that has
    /// never seen `cameraPose` will skip it, which is better than mislabelling it.
    public static func sensorLoggerFileName(for sensor: SensorID) -> String {
        let name = switch sensor {
        case .accelerometer: "AccelerometerUncalibrated"
        case .gyroscope: "GyroscopeUncalibrated"
        case .magnetometer: "MagnetometerUncalibrated"
        case .userAcceleration: "Accelerometer"
        case .rotationRate: "Gyroscope"
        case .magneticField: "Magnetometer"
        case .gravity: "Gravity"
        case .orientation: "Orientation"
        case .location: "Location"
        case .barometer: "Barometer"
        case .compass: "Compass"
        case .loudness: "Microphone"
        case .pedometer: "Pedometer"
        case .battery: "Battery"
        case .brightness: "Brightness"
        case .network: "Network"
        case .headphoneOrientation: "HeadphoneOrientation"
        case .cameraPose: "CameraPose"
        }
        return "\(name).csv"
    }

    /// Sensor Logger's `metadata.csv` — one header row and one data row.
    public static func sensorLoggerMetadataCSV(_ metadata: RecordingMetadata) -> String {
        let started = metadata.startedAt.timeIntervalSince1970
        return """
        version,device name,recording time,platform,appVersion,standardisation
        1,\(RecordingExporter.csvEscape(metadata.device.model)),\
        \(Int64((started * 1000).rounded())),\
        \(metadata.device.systemName),\
        \(RecordingExporter.csvEscape(metadata.device.appVersion)),\
        sensorstorm

        """
    }

    // MARK: - Helpers

    /// `%.12g` round-trips a latitude to well under a millimetre without printing
    /// `0.30000000000000004`. Non-finite becomes an empty field, which every parser in this
    /// ecosystem reads as missing.
    private static func field(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.12g", value)
    }
}
