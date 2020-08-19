//
//  XPCRequestHandler.swift
//  DeltaXPC
//
//  Created by Riley Testut on 8/3/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CoreServices

import DeltaCore
import NESDeltaCore
import SNESDeltaCore
import GBCDeltaCore
import MelonDSDeltaCore
import GBADeltaCore

let CFMessagePortHandler: CFMessagePortCallBack = { (port, msgid, data, info) in
    return nil
}

let CFMachRegistrationCallback: CFMachPortCallBack = { (port, message, index, info) in
    print("Registered", port)
    
//    var surfacePort: mach_port_t = 0
//    RSTReceivePort(message, &surfacePort)
//    print("Port!", surfacePort)
//    
//    let surface = IOSurfaceLookupFromMachPort(surfacePort)
//    print("This is it...:", surface)
}

class MyMachPort: NSMachPort
{
    let myDelegate: NSMachPortDelegate?
    let port: NSMachPort
    
    init(delegate: NSMachPortDelegate?, machPort: UInt32)
    {
        self.myDelegate = delegate
        
        self.port = NSMachPort(machPort: machPort)
        
        super.init(machPort: machPort, options: [])
    }
    
    required init?(coder: NSCoder)
    {
        fatalError()
    }
    
    override func delegate() -> NSMachPortDelegate? {
        return self.myDelegate
    }
    
    override func schedule(in runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        self.port.schedule(in: runLoop, forMode: mode)
    }
}

extension XPCRequestHandler
{
    enum RequestError: Error
    {
        case invalidRequest
        case unknownRequest
    }
}

@objc(XPCRequestHandler) @objcMembers
class XPCRequestHandler: NSObject, NSExtensionRequestHandling
{
    private var extensionContext: NSExtensionContext?
    private var emulationConnection: NSXPCConnection?
    private var emulatorBridge: EmulatorBridging?
    
    private var messagePort: CFMessagePort?
    private var machPort: NSMachPort?
    
    private let messageDelegate = MachMessageDelegate()
    
    private var mainProcess: MainProcessProtocol?
    
    func beginRequest(with context: NSExtensionContext)
    {
        Delta.register(NES.core)
        Delta.register(GBC.core)
        Delta.register(SNES.core)
        Delta.register(GBA.core)
        Delta.register(MelonDS.core)
        
        self.extensionContext = context
        
        guard
            let extensionItem = context.inputItems.first as? NSExtensionItem,
            let itemProvider = extensionItem.attachments?.first,
            itemProvider.hasItemConformingToTypeIdentifier(kUTTypePropertyList as String)
        else { return self.finish(error: RequestError.invalidRequest) }
        
        itemProvider.loadItem(forTypeIdentifier: kUTTypePropertyList as String, options: nil) { (request, error) in
            guard let request = request as? [String: Any] else { return self.finish(error: error ?? RequestError.invalidRequest) }
            
            if let type = request["type"] as? String, type == "start-game"
            {
                self.handleStartGameRequest(request)
            }
            else
            {
                self.finish(error: RequestError.unknownRequest)
            }
        }
    }
}

private extension XPCRequestHandler
{
    func handleStartGameRequest(_ request: [String: Any])
    {
        do
        {
            guard let gameType = request["gameType"] as? GameType,
                  let endpoint = request["endpoint"] as? ListenerEndpoint
            else { throw RequestError.invalidRequest }
            
            let connection = NSXPCConnection(listenerEndpoint: endpoint.endpoint)
            
            let emulatorBridgeInterface = NSXPCInterface(with: EmulatorBridging.self)
            emulatorBridgeInterface.setInterface(NSXPCInterface(with: AudioRendering.self), for: #selector(setter: EmulatorBridging.audioRenderer), argumentIndex: 0, ofReply: false)
            emulatorBridgeInterface.setInterface(NSXPCInterface(with: VideoRendering.self), for: #selector(setter: EmulatorBridging.videoRenderer), argumentIndex: 0, ofReply: false)
            
            let exportedInterface = NSXPCInterface(with: EmulatorProcessProtocol.self)
            exportedInterface.setInterface(emulatorBridgeInterface, for: #selector(EmulatorProcessProtocol.startProcess(completion:)), argumentIndex: 0, ofReply: true)
            connection.exportedInterface = exportedInterface
            
            if let core = Delta.core(for: gameType)
            {
                self.emulatorBridge = core.emulatorBridge
            }
            
            connection.exportedObject = self
            
            connection.remoteObjectInterface = NSXPCInterface(with: MainProcessProtocol.self)
            connection.resume()
            
            self.mainProcess = connection.remoteObjectProxyWithErrorHandler { (error) in
                print("XPC Proxy error:", error)
            } as? MainProcessProtocol
            self.mainProcess?.ping()
            
            self.emulationConnection = connection
        }
        catch
        {
            self.finish(error: error)
        }
    }
    
    func finish(error: Error?)
    {
        if let error = error
        {
            self.extensionContext?.cancelRequest(withError: error)
        }
        else
        {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}

extension XPCRequestHandler: EmulatorProcessProtocol
{
    func startProcess(completion: @escaping (EmulatorBridging) -> Void)
    {
        guard let bridge = self.emulatorBridge else { return }
        completion(bridge)
    }
    
    func stopProcess()
    {
        exit(0)
    }
}