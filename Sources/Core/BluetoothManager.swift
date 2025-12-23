import Foundation
import CoreBluetooth

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let rssi: Int
    let name: String
}

class BluetoothManager: NSObject, ObservableObject {
    private var centralManager: CBCentralManager!
    private var writeCharacteristic: CBCharacteristic?
    
    @Published var isConnected = false
    @Published var isPoweredOn = false
    @Published var connectionStatus = "Disconnected"
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var isScanning = false
    @Published var logs: [String] = []
    
    var connectedPeripheral: CBPeripheral?
    
    @Published var workingVariant: LEDProtocol.ProtocolVariant? = nil
    @Published var isProbing = false
    
    private var availableWriteChars: [CBCharacteristic] = []
    private var currentlyTestedVariant: LEDProtocol.ProtocolVariant? = nil
    
    // Priority Write UUIDs for ELK-BLEDDM Chipsets
    private let priorityWriteUUIDs = [
        CBUUID(string: "FFE9"), // Primary for many ELK devices
        CBUUID(string: "FFE1"), // Common alternative
        CBUUID(string: "FFF3")  // Lotus Lantern original
    ]
    
    // UUIDs for BLEDDM / Lotus Lantern
    private let serviceUUIDs = [CBUUID(string: "FFF0"), CBUUID(string: "FFE0")]
    private let writeCharacteristics = [
        CBUUID(string: "FFE9"),
        CBUUID(string: "FFE1"),
        CBUUID(string: "FFF3"), 
        CBUUID(string: "FFF4")
    ]
    
    // Reconnection Logic
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private let maxReconnectAttempts = 10
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        log("System initialized")
    }
    
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let fullMessage = "[\(timestamp)] \(message)"
        
        DispatchQueue.main.async {
            self.logs.append(fullMessage)
            if self.logs.count > 100 { self.logs.removeFirst() }
            print(fullMessage) // Console backup
        }
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { 
            log("Scan failed: Bluetooth not powered on")
            return 
        }
        
        isScanning = true
        // We don't removeAll here to avoid flickering during auto-refresh, 
        // but we will update them.
        log("Scanning started (ALL peripherals + Connected)")
        
        // 1. Scan for new devices (AllowDuplicates = true for real-time RSSI updates)
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        
        // 2. Retrieve peripherals already connected by the system
        fetchConnectedDevices()
    }
    
    func fetchConnectedDevices() {
        // Try to find devices already connected by iOS (Settings -> Bluetooth)
        // These won't show up in scan results
        let connected = centralManager.retrieveConnectedPeripherals(withServices: serviceUUIDs)
        for peripheral in connected {
            handleDiscoveredPeripheral(peripheral, rssi: -50, isConnectedBySystem: true)
        }
        
        // Also try general "connected" retrieve if specific services fail
        // Note: passing empty array to retrieveConnectedPeripherals is not allowed in iOS
    }
    
    func refresh() {
        stopScanning()
        DispatchQueue.main.async {
            self.discoveredDevices.removeAll()
            self.startScanning()
        }
    }
    
    func stopScanning() {
        isScanning = false
        centralManager.stopScan()
        log("Scanning stopped")
    }
    
    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
        connectionStatus = "Connecting..."
        log("Connecting to: \(peripheral.name ?? "Unknown") [\(peripheral.identifier.uuidString)]")
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }
    
    func disconnect() {
        if let peripheral = connectedPeripheral {
            log("User requested disconnect from: \(peripheral.name ?? "Unknown")")
            centralManager.cancelPeripheralConnection(peripheral)
        }
        reconnectTimer?.invalidate()
        reconnectAttempt = 0
    }
    
    func togglePower() {
        let newState = !isPoweredOn
        setPower(on: newState)
        Haptics.play(.medium)
    }
    
    func setPower(on: Bool) {
        let variant = workingVariant ?? .a
        send(LEDProtocol.power(on: on, variant: variant))
        isPoweredOn = on
    }
    
    func setColor(r: Int, g: Int, b: Int) {
        let variant = workingVariant ?? .a
        send(LEDProtocol.color(r: r, g: g, b: b, variant: variant))
    }
    
    func setBrightness(_ value: Int) {
        let variant = workingVariant ?? .a
        send(LEDProtocol.brightness(value, variant: variant))
    }
    
    func setEffectSpeed(_ value: Int) {
        let variant = workingVariant ?? .a
        send(LEDProtocol.speed(value)) // Speed doesn't vary much but we'll keep it standard
    }
    
    func setMode(_ value: UInt8) {
        let variant = workingVariant ?? .a
        send(LEDProtocol.mode(value))
    }
    
    func lockVariant(_ variant: LEDProtocol.ProtocolVariant) {
        DispatchQueue.main.async {
            self.workingVariant = variant
            self.log("Protocol LOCKED: \(variant)")
        }
    }
    
    private let bleQueue = DispatchQueue(label: "com.ledglow.ble")
    
    func sendRawHex(_ hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").uppercased()
        guard let data = cleaned.hexData() else {
            log("TX Error: Invalid HEX")
            return
        }
        send(Array(data))
    }
    
    private func send(_ bytes: [UInt8]) {
        bleQueue.async {
            // DOUBLE-SEND LOGIC (50ms delay) for hardware reliability
            self.sendDirect(bytes)
            Thread.sleep(forTimeInterval: 0.05)
            self.sendDirect(bytes)
        }
    }
    
    func startProbing() {
        guard let p = connectedPeripheral, !availableWriteChars.isEmpty else { 
            log("Probe failed: No write characteristics available")
            return 
        }
        
        DispatchQueue.main.async { self.isProbing = true }
        
        bleQueue.async {
            self.log("--- STARTING HARDWARE PROBE ---")
            // 1. Warm-up Delay (Lotus Lantern X requirement)
            Thread.sleep(forTimeInterval: 0.3)
            
            // 2. Send MULTIPLE Priming / APP MODE activation packets
            self.log("Sending MULTIPLE APP MODE Priming Packets...")
            for packet in LEDProtocol.primingPackets {
                self.sendDirect(packet)
                Thread.sleep(forTimeInterval: 0.08) // 80ms delay between priming packets
            }
            
            for char in self.availableWriteChars {
                if self.workingVariant != nil { break }
                
                self.writeCharacteristic = char
                self.log("Probing Characteristic: \(char.uuid.uuidString)")
                
                for variant in LEDProtocol.ProtocolVariant.allCases {
                    if self.workingVariant != nil { break }
                    
                    self.currentlyTestedVariant = variant
                    self.log("Testing Variant: \(variant)")
                    
                    // Power ON (Double Shot)
                    let pwrPacket = LEDProtocol.power(on: true, variant: variant)
                    self.sendDirect(pwrPacket)
                    Thread.sleep(forTimeInterval: 0.05)
                    self.sendDirect(pwrPacket)
                    
                    // WAIT 150ms
                    Thread.sleep(forTimeInterval: 0.15)
                    
                    // Set RED (Visual identification)
                    let redPacket = LEDProtocol.color(r: 255, g: 0, b: 0, variant: variant)
                    self.sendDirect(redPacket)
                    
                    // WAIT 150ms
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }
            
            self.currentlyTestedVariant = nil
            DispatchQueue.main.async { self.isProbing = false }
            self.log("--- PROBE SEQUENCE FINISHED ---")
        }
    }

    private func sendDirect(_ bytes: [UInt8]) {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { 
            log("TX Skip: Not connected or no write char")
            return 
        }
        
        // Final length validation
        guard bytes.count == 9 else {
            log("TX Warning: Packet length is \(bytes.count) (Expected 9)")
            return
        }

        let data = Data(bytes)
        // MUST USE .withoutResponse for ELK-BLEDDM hardware
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        
        let hexString = bytes.map { String(format: "%02X", $0) }.joined(separator: "")
        log("TX: \(hexString)")
    }
    
    private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral, rssi: Int, isConnectedBySystem: Bool = false) {
        let name = peripheral.name ?? "Unknown"
        let uuid = peripheral.identifier.uuidString
        
        // BROAD FILTER
        let lowerName = name.lowercased()
        let isLED = lowerName.contains("led") || 
                    lowerName.contains("ble") || 
                    lowerName.contains("elk") || 
                    lowerName.contains("dm") ||
                    lowerName.contains("om")
        
        if isLED || name != "Unknown" {
            DispatchQueue.main.async {
                if let index = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
                    // Update existing
                    self.discoveredDevices[index] = DiscoveredDevice(
                        id: peripheral.identifier, 
                        peripheral: peripheral, 
                        rssi: isConnectedBySystem ? -30 : rssi, 
                        name: isConnectedBySystem ? "\(name) (Connected)" : name
                        
                    )
                } else {
                    // Add new
                    self.log("Found: \(name) [\(uuid)] (\(rssi)dBm)\(isConnectedBySystem ? " [SYSTEM CONNECTED]" : "")")
                    self.discoveredDevices.append(DiscoveredDevice(
                        id: peripheral.identifier, 
                        peripheral: peripheral, 
                        rssi: isConnectedBySystem ? -30 : rssi, 
                        name: isConnectedBySystem ? "\(name) (Connected)" : name
                    ))
                }
                // Always sort by signal strength
                self.discoveredDevices.sort { $0.rssi > $1.rssi }
            }
        }
    }
    
    private func handleDisconnection() {
        isConnected = false
        writeCharacteristic = nil
        
        if reconnectAttempt < maxReconnectAttempts {
            reconnectAttempt += 1
            let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
            connectionStatus = "Retrying in \(Int(delay))s (#\(reconnectAttempt))"
            log("Connection lost. Retry #\(reconnectAttempt) in \(Int(delay))s")
            
            reconnectTimer?.invalidate()
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self = self, let p = self.connectedPeripheral else { return }
                self.log("Automatic reconnection attempt...")
                self.centralManager.connect(p, options: nil)
            }
        } else {
            connectionStatus = "Disconected"
            log("Max reconnection attempts reached")
        }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: \(central.state == .poweredOn ? "ON" : "OFF (\(central.state.rawValue))")")
        if central.state == .poweredOn {
            startScanning()
        } else {
            connectionStatus = "Bluetooth Unavailable"
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi: NSNumber) {
        handleDiscoveredPeripheral(peripheral, rssi: rssi.intValue)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectionStatus = "Connected"
        reconnectAttempt = 0
        reconnectTimer?.invalidate()
        log("Connected to \(peripheral.name ?? "Device"). Discovering services...")
        peripheral.delegate = self
        peripheral.discoverServices(nil) // Discover all services for robustness
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Connect failed: \(error?.localizedDescription ?? "Unknown error")")
        handleDisconnection()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "Clean disconnect")")
        handleDisconnection()
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { 
            log("No services found")
            return 
        }
        
        for service in services {
            log("Service found: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            let props = characteristic.properties
            let canWrite = props.contains(.write) || props.contains(.writeWithoutResponse)
            
            if canWrite {
                if !availableWriteChars.contains(where: { $0.uuid == characteristic.uuid }) {
                    availableWriteChars.append(characteristic)
                    log("  Found Write Char: \(characteristic.uuid.uuidString)")
                }
            }
            
            // Auto-enable notifications on potential status chars (FFF4, FFE2, etc.)
            if props.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
                log("  Subscribed to Notify: \(characteristic.uuid.uuidString)")
            }
        }
        
        // Sort available chars by priority
        availableWriteChars.sort { (c1, c2) -> Bool in
            let idx1 = priorityWriteUUIDs.firstIndex(of: c1.uuid) ?? 99
            let idx2 = priorityWriteUUIDs.firstIndex(of: c2.uuid) ?? 99
            return idx1 < idx2
        }
        
        // If we found any target characteristic, pick the best one and start probing
        if writeCharacteristic == nil, let best = availableWriteChars.first {
            writeCharacteristic = best
            log("Best Match Characteristic: \(best.uuid.uuidString)")
            
            // Start Probing sequence
            startProbing()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value {
            let hex = data.map { String(format: "%02X", $0) }.joined()
            log("RX [\(characteristic.uuid.uuidString)]: \(hex)")
            
            // AUTO-LOCK Variant if any notification is received during probing
            if isProbing, let testing = currentlyTestedVariant, workingVariant == nil {
                log("AUTO-DETECT: Notification received! Locking variant: \(testing)")
                lockVariant(testing)
            }
        }
    }
}

extension String {
    func hexData() -> Data? {
        var data = Data(capacity: count / 2)
        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{1,2}", options: .caseInsensitive)
        regex.enumerateMatches(in: self, range: NSRange(location: 0, length: count)) { match, _, _ in
            if let match = match {
                let byteString = (self as NSString).substring(with: match.range)
                if let num = UInt8(byteString, radix: 16) {
                    data.append(num)
                }
            }
        }
        return data.count > 0 ? data : nil
    }
}
