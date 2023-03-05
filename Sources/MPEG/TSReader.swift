import AVFoundation
import Foundation
import Logboard

/// The interface an MPEG-2 TS (Transport Stream) reader uses to inform its delegates.
public protocol TSReaderDelegate: AnyObject {
    func reader(_ reader: TSReader, id: UInt16, didReadCMSampleBuffer sampleBuffer: CMSampleBuffer)
}

/// The TSReader class represents read MPETF-2 transport stream data.
public class TSReader {
    /// Specifies the delegate object.
    public weak var delegate: TSReaderDelegate?

    private var pat: TSProgramAssociation? {
        didSet {
            guard let PAT = pat else {
                return
            }
            for (channel, PID) in PAT.programs {
                programs[PID] = channel
            }
            if logger.isEnabledFor(level: .trace) {
                logger.trace(programs)
            }
        }
    }
    private var pmt: [UInt16: TSProgramMap] = [:] {
        didSet {
            for (_, pmt) in pmt {
                for data in pmt.elementaryStreamSpecificData {
                    esSpecData[data.elementaryPID] = data
                }
            }
            if logger.isEnabledFor(level: .trace) {
                logger.trace(esSpecData)
            }
        }
    }
    private var nalUnitReader = NALUnitReader()
    private var programs: [UInt16: UInt16] = [:]
    private var esSpecData: [UInt16: ESSpecificData] = [:]
    private var formatDescriptions: [UInt16: CMFormatDescription] = [:]
    private var packetizedElementaryStreams: [UInt16: PacketizedElementaryStream] = [:]

    /// Create a  new TSReader instance.
    public init() {
    }

    /// Reads transport-stream data.
    public func read(_ data: Data) -> Int {
        let count = data.count / TSPacket.size
        for i in 0..<count {
            guard let packet = TSPacket(data: data.subdata(in: i * TSPacket.size..<(i + 1) * TSPacket.size)) else {
                continue
            }
            if packet.pid == 0x0000 {
                pat = TSProgramAssociation(packet.payload)
                continue
            }
            if let channel = programs[packet.pid] {
                pmt[channel] = TSProgramMap(packet.payload)
                continue
            }
            readPacketizedElementaryStream(packet)
        }
        return count * TSPacket.size
    }

    /// Clears the reader object for new transport stream.
    public func clear() {
        pat = nil
        pmt.removeAll()
        programs.removeAll()
        esSpecData.removeAll()
        formatDescriptions.removeAll()
        packetizedElementaryStreams.removeAll()
    }

    private func readPacketizedElementaryStream(_ packet: TSPacket) {
        if packet.payloadUnitStartIndicator {
            if let sampleBuffer = makeSampleBuffer(packet.pid, forUpdate: true) {
                delegate?.reader(self, id: packet.pid, didReadCMSampleBuffer: sampleBuffer)
            }
            packetizedElementaryStreams[packet.pid] = PacketizedElementaryStream(packet.payload)
            return
        }
        _ = packetizedElementaryStreams[packet.pid]?.append(packet.payload)
        if let sampleBuffer = makeSampleBuffer(packet.pid) {
            delegate?.reader(self, id: packet.pid, didReadCMSampleBuffer: sampleBuffer)
        }
    }

    private func makeSampleBuffer(_ id: UInt16, forUpdate: Bool = false) -> CMSampleBuffer? {
        guard
            let data = esSpecData[id],
            var pes = packetizedElementaryStreams[id], pes.isEntired || forUpdate else {
            return nil
        }
        defer {
            packetizedElementaryStreams[id] = nil
        }
        if formatDescriptions[id] == nil {
            formatDescriptions[id] = makeFormatDescription(data, pes: pes)
        }
        return pes.makeSampleBuffer(data.streamType, formatDescription: formatDescriptions[id])
    }

    private func makeFormatDescription(_ data: ESSpecificData, pes: PacketizedElementaryStream) -> CMFormatDescription? {
        switch data.streamType {
        case .adtsAac:
            return ADTSHeader(data: pes.data).makeFormatDescription()
        case .h264:
            return nalUnitReader.makeFormatDescription(pes.data)
        default:
            return nil
        }
    }
}
