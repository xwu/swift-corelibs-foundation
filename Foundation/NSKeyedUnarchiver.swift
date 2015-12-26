// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2015 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

import CoreFoundation

public class NSKeyedUnarchiver : NSCoder {
    struct UnarchiverFlags : OptionSetType {
        let rawValue : UInt
        
        init(rawValue : UInt) {
            self.rawValue = rawValue
        }
        
        static let None = UnarchiverFlags(rawValue: 0)
        static let FinishedDecoding = UnarchiverFlags(rawValue : 1)
        static let RequiresSecureCoding = UnarchiverFlags(rawValue: 2)
    }
    
    class DecodingContext {
        private var dict : Dictionary<String, Any>
        private var genericKey : UInt = 0
        
        init(_ dict : Dictionary<String, Any>) {
            self.dict = dict
        }
    }
    
    private static var _classNameMap : Dictionary<String, AnyClass> = [:]
    
    public weak var delegate: NSKeyedUnarchiverDelegate?
    
    private var _stream : AnyObject
    private var _flags = UnarchiverFlags(rawValue: 0)
    private var _containers : Array<DecodingContext>? = nil
    private var _objects : Array<Any> = [NSKeyedArchiveNullObjectReferenceName]
    private var _objRefMap : Dictionary<UInt32, AnyObject> = [:]
    private var _replacementMap : Dictionary<NSUniqueObject, AnyObject> = [:]
    private var _classNameMap : Dictionary<String, AnyClass> = [:]
    private var _classes : Dictionary<UInt32, AnyClass> = [:]
    private var _cache : Array<CFKeyedArchiverUID> = []
    private var _allowedClasses : Array<[AnyClass]> = []
    private var _error : NSError? = nil
    
    internal override var error: NSError? {
        return _error
    }
    
    public class func unarchiveObjectWithData(data: NSData) -> AnyObject? {
        do {
            return try unarchiveTopLevelObjectWithData(data)
        } catch {
        }
        return nil
    }
    
    public class func unarchiveObjectWithFile(path: String) -> AnyObject? {
        let url = NSURL(fileURLWithPath: path)
        let readStream = CFReadStreamCreateWithFile(kCFAllocatorSystemDefault, url._cfObject)
        var root : AnyObject? = nil
        
        if !CFReadStreamOpen(readStream) {
            return nil
        }
        
        if let keyedUnarchiver = NSKeyedUnarchiver(stream: readStream) {
            do {
                try root = keyedUnarchiver.decodeTopLevelObjectForKey(NSKeyedArchiveRootObjectKey)
                keyedUnarchiver.finishDecoding()
            } catch {
            }
        }
        
        CFReadStreamClose(readStream)
        
        return root
    }
    
    public convenience init?(forReadingWithData data: NSData) {
        self.init(stream: data)
    }
    
    private init?(stream: AnyObject) {
        self._stream = stream
        super.init()
        
        do {
            try _readPropertyList()
        } catch let error as NSError {
            if let debugDescription = error.userInfo["NSDebugDescription"] {
                print("*** NSKeyedUnarchiver.init: \(debugDescription)")
            }
        } catch {
            return nil
        }
    }
    
    private func _readPropertyList() throws {
        var plist : Any? = nil
        var format = NSPropertyListFormat.BinaryFormat_v1_0
        
        // FIXME this implementation reads the entire property list into memory
        // which will not scale for large archives. We should support incremental
        // unarchiving, but that will be a considerable amount of work.
        
        if let data = self._stream as? NSData {
            try plist = NSPropertyListSerialization.propertyListWithData(data, options: NSPropertyListMutabilityOptions.Immutable, format: &format)
        } else {
            try plist = NSPropertyListSerialization.propertyListWithStream(self._stream as! CFReadStream,
                                                                           length: 0,
                                                                                   options: NSPropertyListMutabilityOptions.Immutable,
                                                                                            format: &format)
        }
        
        guard let unwrappedPlist = plist as? Dictionary<String, Any> else {
            throw _decodingError(NSCocoaError.PropertyListReadCorruptError,
                                 withDescription: "Unable to read archive. The data may be corrupt.")
        }
        
        let archiver = unwrappedPlist["$archiver"] as? String
        if archiver != String(NSKeyedArchiver.self) {
            throw _decodingError(NSCocoaError.PropertyListReadCorruptError,
                                 withDescription: "Unknown archiver. The data may be corrupt.")
        }
        
        let version = unwrappedPlist["$version"] as? NSNumber
        if version?.intValue != Int32(NSKeyedArchivePlistVersion) {
            throw _decodingError(NSCocoaError.PropertyListReadCorruptError,
                                 withDescription: "Unknown archive version. The data may be corrupt.")
        }
        
        let top = unwrappedPlist["$top"] as? Dictionary<String, Any>
        let objects = unwrappedPlist["$objects"] as? Array<Any>
        
        if top == nil || objects == nil {
            throw _decodingError(NSCocoaError.PropertyListReadCorruptError,
                                 withDescription: "Unable to read archive contents. The data may be corrupt.")
        }
        
        self._objects = objects!
        self._containers = [DecodingContext(top!)]
    }
    
    private class func _unescapeKey(key : String) -> String {
        if key.hasPrefix("$") {
            return key.bridge().substringFromIndex(1)
        }
        
        return key
    }
    
    private func _pushDecodingContext(decodingContext: DecodingContext) {
        self._containers!.append(decodingContext)
    }
    
    private func _popDecodingContext() {
        self._containers!.removeLast()
    }
    
    private var _currentDecodingContext : DecodingContext {
        return self._containers!.last!
    }
    
    private func _nextGenericKey() -> String {
        let key = "$" + String(_currentDecodingContext.genericKey)
        _currentDecodingContext.genericKey += 1
        return key
    }
    
    private func _objectInCurrentDecodingContext<T>(forKey key: String?) -> T? {
        var unwrappedKey = key
        
        if key != nil {
            unwrappedKey = NSKeyedUnarchiver._unescapeKey(key!)
        } else {
            unwrappedKey = _nextGenericKey()
        }
        
        return _currentDecodingContext.dict[unwrappedKey!] as? T
    }
    
    /**
     Dereferences, but does not decode, an object reference
     */
    private func _dereferenceObjectReference(unwrappedObjectRef: CFKeyedArchiverUID) -> Any? {
        let uid = Int(objectRefGetValue(unwrappedObjectRef))
        
        guard uid < self._objects.count else {
            return nil
        }
        
        if uid == 0 {
            return nil
        }
        
        return self._objects[uid]
    }
    
    public override var systemVersion: UInt32 {
        return NSKeyedArchiverSystemVersion
    }
    
    public override var allowsKeyedCoding: Bool {
        get {
            return true
        }
    }
    
    private func _validateStillDecoding() -> Bool {
        if self._flags.contains(UnarchiverFlags.FinishedDecoding) {
            fatalError("Decoder already finished")
        }
        
        return true
    }
    
    private class func _supportsSecureCoding(clsv : AnyClass) -> Bool {
        if let secureCodable = clsv as? NSSecureCoding.Type {
            return secureCodable.supportsSecureCoding()
        }
        
        return false
    }
    
    // FIXME is there a better way to do this with Swift stdlib?
    private class func _classIsKindOfClass(assertedClass : AnyClass, _ allowedClass : AnyClass) -> Bool {
        var superClass : AnyClass? = assertedClass
        
        repeat {
            if superClass == allowedClass {
                return true
            }
            
            superClass = _getSuperclass(superClass!)
        } while superClass != nil
        
        return false
    }
    
    private func _isClassAllowed(assertedClass: AnyClass?, allowedClasses: [AnyClass]?) -> Bool {
        if assertedClass == nil {
            return false
        }
        
        if _flags.contains(UnarchiverFlags.RequiresSecureCoding) {
            if let unwrappedAllowedClasses = allowedClasses {
                if unwrappedAllowedClasses.contains({NSKeyedUnarchiver._classIsKindOfClass(assertedClass!, $0)}) {
                    return true
                }
            }
            
            fatalError("Value was of unexpected class \(assertedClass!)")
        } else {
            return true
        }
    }
    
    private func _validateAndMapClassDictionary(classDict: Dictionary<String, Any>?,
                                                allowedClasses: [AnyClass]?,
                                                inout classToConstruct: AnyClass?) -> Bool {
        classToConstruct = nil
        
        func _classForClassName(codedName: String) -> AnyClass? {
            var aClass : AnyClass?
            
            aClass = classForClassName(codedName)
            if aClass == nil {
                aClass = NSKeyedUnarchiver.classForClassName(codedName)
            }
            if aClass == nil {
                aClass = NSClassFromString(codedName)
            }
            
            return aClass
        }
        
        guard let unwrappedClassDict = classDict else {
            return false
        }
        
        // TODO is it required to validate the superclass hierarchy?
        let assertedClassName = unwrappedClassDict["$classname"] as? String
        let assertedClassHints = unwrappedClassDict["$classhints"] as? [String]
        let assertedClasses = unwrappedClassDict["$classes"] as? [String]
        
        if assertedClassName != nil {
            let assertedClass : AnyClass? = _classForClassName(assertedClassName!)
            if _isClassAllowed(assertedClass, allowedClasses: allowedClasses) {
                classToConstruct = assertedClass
                return true
            }
        }
        
        if assertedClassHints != nil {
            for assertedClassHint in assertedClassHints! {
                // FIXME check whether class hints should be subject to mapping or not
                let assertedClass : AnyClass? = NSClassFromString(assertedClassHint)
                if _isClassAllowed(assertedClass, allowedClasses: allowedClasses) {
                    classToConstruct = assertedClass
                    return true
                }
            }
        }
        
        if assertedClassName != nil {
            if let unwrappedDelegate = self.delegate {
                classToConstruct = unwrappedDelegate.unarchiver(self,
                                                                cannotDecodeObjectOfClassName: assertedClassName!,
                                                                originalClasses: assertedClasses != nil ? assertedClasses! : [])
                if classToConstruct != nil {
                    return true
                }
            }
        }
        
        return false
    }
    
    /**
        Validate a class reference against a class list, and return the class object if allowed
     */
    private func _validateAndMapClassReference(classReference: CFKeyedArchiverUID,
                                               allowedClasses: [AnyClass]?) throws -> AnyClass? {
        let classUid = objectRefGetValue(classReference)
        var classToConstruct : AnyClass? = _classes[classUid]
 
        if classToConstruct == nil {
            let classDict = _dereferenceObjectReference(classReference) as? Dictionary<String, Any>
            
            if !_validateAndMapClassDictionary(classDict!,
                                               allowedClasses: allowedClasses,
                                               classToConstruct: &classToConstruct) {
                throw _decodingError(NSCocoaError.CoderReadCorruptError, withDescription: "Invalid class \(classDict). The data may be corrupt.")
            }
            
            _classes[classUid] = classToConstruct
        }
        
        return classToConstruct
    }
    
    /**
        Returns true if objectOrReference represents a reference to another object in the archive
     */
    internal class func _isReference(objectOrReference : Any?) -> Bool {
        if let cf = objectOrReference as? AnyObject {
            return CFGetTypeID(cf) == _CFKeyedArchiverUIDGetTypeID()
        } else {
            return false
        }
    }
    
    private func _cachedObjectForReference(objectRef: CFKeyedArchiverUID) -> AnyObject? {
        return self._objRefMap[objectRefGetValue(objectRef)]
    }
    
    private func _cacheObject(object: AnyObject, forReference objectRef: CFKeyedArchiverUID) {
        self._objRefMap[objectRefGetValue(objectRef)] = object
    }
    
    private func _isNullObjectReference(objectRef: CFKeyedArchiverUID) -> Bool {
        return objectRefGetValue(objectRef) == 0
    }
    
    /**
        Returns true if the object is a dictionary representing a object rather than a value type
     */
    private func _isContainer(object: Any) -> Bool {
        guard let dict = object as? Dictionary<String, Any> else {
            return false
        }
        
        let classRef = dict["$class"]
        
        return NSKeyedUnarchiver._isReference(classRef)
    }
    
    
    /**
        Replace object with another one
     */
    private func replaceObject(object: AnyObject, withObject replacement: AnyObject) {
        let oid = NSUniqueObject(object)
        
        if let unwrappedDelegate = self.delegate {
            unwrappedDelegate.unarchiver(self, willReplaceObject: object, withObject: replacement)
        }
        
        self._replacementMap[oid] = replacement
    }
    
    private func _decodingError(code: NSCocoaError, withDescription description: String) -> NSError {
        return NSError(domain: NSCocoaErrorDomain,
                               code: code.rawValue, userInfo: [ "NSDebugDescription" : description ])
    }
    
    private func _replacementObject(decodedObject: AnyObject?) -> AnyObject? {
        var object : AnyObject? = nil // object to encode after substitution
        
        // nil cannot be mapped
        if decodedObject == nil {
            return nil
        }
        
        // check replacement cache
        object = self._replacementMap[NSUniqueObject(decodedObject!)]
        if object != nil {
            return object
        }
        
        // object replaced by delegate. If the delegate returns nil, nil is encoded
        if let unwrappedDelegate = self.delegate {
            object = unwrappedDelegate.unarchiver(self, didDecodeObject: decodedObject!)
            if object != nil {
                replaceObject(decodedObject!, withObject: object!)
                return object
            }
        }
        
        return decodedObject
    }
    
    private func _validateClassSupportsSecureCoding(classToConstruct : AnyClass?) -> Bool {
        var supportsSecureCoding : Bool = false
        
        if let secureDecodableClass = classToConstruct as? NSSecureCoding.Type {
            supportsSecureCoding = secureDecodableClass.supportsSecureCoding()
        }
        
        if self.requiresSecureCoding && !supportsSecureCoding {
            // FIXME should this be a fatal error?
            fatalError("Archiver \(self) requires secure coding but class \(classToConstruct) does not support it")
        }
        
        return supportsSecureCoding
    }
    
    /**
        Decode an object for the given reference
     */
    private func _decodeObject(objectRef: CFKeyedArchiverUID) throws -> AnyObject? {
        var object : AnyObject? = nil
        
        _validateStillDecoding()
        
        if !NSKeyedUnarchiver._isReference(objectRef) {
            throw _decodingError(NSCocoaError.CoderReadCorruptError,
                                 withDescription: "Object \(objectRef) is not a reference. The data may be corrupt.")
        }
        if _isNullObjectReference(objectRef) {
            // reference to the nil object
            object = nil
        } else {
            guard let dereferencedObject = _dereferenceObjectReference(objectRef) else {
                throw _decodingError(NSCocoaError.CoderReadCorruptError,
                                     withDescription: "Invalid object reference \(objectRef). The data may be corrupt.")
            }
            
            if _isContainer(dereferencedObject) {
                // check cached of decoded objects
                object = _cachedObjectForReference(objectRef)
                if object == nil {
                    guard let dict = dereferencedObject as? Dictionary<String, Any> else {
                        throw _decodingError(NSCocoaError.CoderReadCorruptError,
                                             withDescription: "Invalid object encoding \(objectRef). The data may be corrupt.")
                    }
		
                    let innerDecodingContext = DecodingContext(dict)

                    let classReference = innerDecodingContext.dict["$class"] as? CFKeyedArchiverUID
                    if !NSKeyedUnarchiver._isReference(classReference) {
                        throw _decodingError(NSCocoaError.CoderReadCorruptError,
                                             withDescription: "Invalid class reference \(classReference). The data may be corrupt.")
                    }

                    var classToConstruct : AnyClass? = try _validateAndMapClassReference(classReference!,
                                                                                         allowedClasses: self.allowedClasses)
                    
                    _pushDecodingContext(innerDecodingContext)
                    defer { _popDecodingContext() } // ensure an error does not invalidate the decoding context stack

                    if let ns = classToConstruct as? NSObject.Type {
                        classToConstruct = ns.classForKeyedUnarchiver()
                    }
                    
                    guard let decodableClass = classToConstruct as? NSCoding.Type else {
                        throw _decodingError(NSCocoaError.CoderReadCorruptError,
                                             withDescription: "Class \(classToConstruct) is not decodable. The data may be corrupt.")
                    }
                    
                    _validateClassSupportsSecureCoding(classToConstruct)
                    
                    object = decodableClass.init(coder: self) as? AnyObject
                    
                    _cacheObject(object!, forReference: objectRef)
                }
            } else {
                // reference to a non-container object
                // FIXME remove these special cases
                if let str = dereferencedObject as? String {
                    object = str.bridge()
                } else {
                    object = dereferencedObject as? AnyObject
                }
            }
        }
        
        return _replacementObject(object)
    }
    
    /**
     Internal function to decode an object. Returns the decoded object or throws an error.
     */
    private func _decodeObject(forKey key: String?) throws -> AnyObject? {
        guard let objectRef : AnyObject? = _objectInCurrentDecodingContext(forKey: key) else {
            throw _decodingError(NSCocoaError.CoderValueNotFoundError,
                                 withDescription: "No value found for key \(key). The data may be corrupt.")
        }
        
        return try _decodeObject(objectRef!)
    }
    
    /**
     Decode a value type in the current decoding context
     */
    private func _decodeValueForKey<T>(key: String?) -> T? {
        _validateStillDecoding()
        return _objectInCurrentDecodingContext(forKey: key)
    }
    
    /**
     Helper for NSArray/NSDictionary to dereference and decode an array of objects
     */
    internal func _decodeArray(key : String, withBlock block: (Any) -> Void) throws {
        let objectRefs : Array<Any>? = _decodeValueForKey(key)
        
        guard let unwrappedObjectRefs = objectRefs else {
            return
        }
        
        for objectRef in unwrappedObjectRefs {
            guard NSKeyedUnarchiver._isReference(objectRef) else {
                return
            }
            
            if let object = try _decodeObject(objectRef as! CFKeyedArchiverUID) {
                block(object)
            }
        }
    }
    
    internal func _decodeArrayOfObjects(key : String) -> Array<AnyObject>? {
        var array : Array<AnyObject> = []
        
        do {
            try _decodeArray(key) { any in
                if let object = any as? AnyObject {
                    array.append(object)
                }
            }
        } catch let error as NSError {
            self._error = error
            return nil
        } catch {
            return nil
        }
        
        return array
    }
    
    /**
     Called when the caller has finished decoding.
     */
    public func finishDecoding() {
        if _flags.contains(UnarchiverFlags.FinishedDecoding) {
            return;
        }
        
        if let unwrappedDelegate = self.delegate {
            unwrappedDelegate.unarchiverWillFinish(self)
        }
        
        // FIXME are we supposed to do anything here?
        
        if let unwrappedDelegate = self.delegate {
            unwrappedDelegate.unarchiverDidFinish(self)
        }
        
        self._flags.insert(UnarchiverFlags.FinishedDecoding)
    }
    
    public class func setClass(cls: AnyClass?, forClassName codedName: String) {
        _classNameMap[codedName] = cls
    }
    
    public func setClass(cls: AnyClass?, forClassName codedName: String) {
        _classNameMap[codedName] = cls
    }
    
    // During decoding, the coder first checks with the coder's
    // own table, then if there was no mapping there, the class's.
    
    public class func classForClassName(codedName: String) -> AnyClass? {
        return _classNameMap[codedName]
    }
    
    public func classForClassName(codedName: String) -> AnyClass? {
        return _classNameMap[codedName]
    }
    
    public override func containsValueForKey(key: String) -> Bool {
        return _decodeValueForKey(key) != nil
    }
    
    public override func decodeObjectForKey(key: String) -> AnyObject? {
        do {
            return try _decodeObject(forKey: key)
        } catch let error as NSError {
            self._error = error
        } catch {
        }
        return nil
    }
    
    @warn_unused_result
    public override func decodeObjectOfClass<DecodedObjectType : NSCoding where DecodedObjectType : NSObject>(cls: DecodedObjectType.Type, forKey key: String) -> DecodedObjectType? {
        let classes = [cls]
        return decodeObjectOfClasses(classes, forKey: key) as? DecodedObjectType
    }
    
    @warn_unused_result
    public override func decodeObjectOfClasses(classes: [AnyClass], forKey key: String) -> AnyObject? {
        do {
            self._allowedClasses.append(classes)
            defer { self._allowedClasses.removeLast() }

            return try _decodeObject(forKey: key)
        } catch let error as NSError {
            self._error = error
        } catch {
        }
        
        return nil
    }
    
    @warn_unused_result
    public override func decodeTopLevelObjectForKey(key: String) throws -> AnyObject? {
        return try decodeTopLevelObjectOfClasses([NSArray.self], forKey: key)
    }
    
    @warn_unused_result
    public override func decodeTopLevelObjectOfClass<DecodedObjectType : NSCoding where DecodedObjectType : NSObject>(cls: DecodedObjectType.Type, forKey key: String) throws -> DecodedObjectType? {
        return try self.decodeTopLevelObjectOfClasses([cls], forKey: key) as! DecodedObjectType?
    }
    
    @warn_unused_result
    public override func decodeTopLevelObjectOfClasses(classes: [AnyClass], forKey key: String) throws -> AnyObject? {
        guard self._containers?.count == 1 else {
            throw _decodingError(NSCocoaError.CoderReadCorruptError,
                                 withDescription: "Can only call decodeTopLevelObjectOfClasses when decoding top level objects.")
        }
        
        return decodeObjectOfClasses(classes, forKey: key)
    }
    
    public override func decodeObject() -> AnyObject? {
        do {
            return try _decodeObject(forKey: nil)
        } catch let error as NSError {
            self._error = error
        } catch {
        }
        
        return nil
    }
    
    public override func decodeBoolForKey(key: String) -> Bool {
        guard let result : Bool = _decodeValueForKey(key) else {
            return false
        }
        return result
    }
    
    public override func decodeIntForKey(key: String) -> Int32  {
        guard let result : Int32 = _decodeValueForKey(key) else {
            return 0
        }
        return result
    }
    
    public override func decodeInt32ForKey(key: String) -> Int32 {
        guard let result : Int32 = _decodeValueForKey(key) else {
            return 0
        }
        return result
    }
    
    public override func decodeInt64ForKey(key: String) -> Int64 {
        guard let result : Int64 = _decodeValueForKey(key) else {
            return 0
        }
        return result
    }
    
    public override func decodeFloatForKey(key: String) -> Float {
        guard let result : Float = _decodeValueForKey(key) else {
            return 0
        }
        return result
    }
    
    public override func decodeDoubleForKey(key: String) -> Double {
        guard let result : Double = _decodeValueForKey(key) else {
            return 0
        }
        return result
    }
    
    public override func decodeIntegerForKey(key: String) -> Int {
        guard let result : Int = _decodeValueForKey(key) else {
            return 0
        }
        return result
    }
    
    // returned bytes immutable, and they go away with the unarchiver, not the containing autorelease pool
    public override func decodeBytesForKey(key: String, returnedLength lengthp: UnsafeMutablePointer<Int>) -> UnsafePointer<UInt8> {
        let ns : NSData? = _decodeValueForKey(key)
        
        if let value = ns {
            lengthp.memory = Int(value.length)
            return UnsafePointer<UInt8>(value.bytes)
        }
        
        return nil
    }
    
    public override func decodeDataObject() -> NSData? {
        return decodeObject() as? NSData
    }
    
    public override func encodePropertyList(aPropertyList: AnyObject) {
        return encodeObject(aPropertyList)
    }
    
    public override func decodePropertyList() -> AnyObject? {
        return decodeObject()
    }
    
    public override var allowedClasses: [AnyClass]? {
        get {
            return self._allowedClasses.last
        }
    }
    
    // Enables secure coding support on this keyed unarchiver. When enabled, anarchiving a disallowed class throws an exception. Once enabled, attempting to set requiresSecureCoding to NO will throw an exception. This is to prevent classes from selectively turning secure coding off. This is designed to be set once at the top level and remain on. Note that the getter is on the superclass, NSCoder. See NSCoder for more information about secure coding.
    public override var requiresSecureCoding: Bool {
        get {
            return _flags.contains(UnarchiverFlags.RequiresSecureCoding)
        }
        set {
            if _flags.contains(UnarchiverFlags.RequiresSecureCoding) {
                if !newValue {
                    fatalError("Cannot unset requiresSecureCoding")
                }
            } else {
                if newValue {
                    _flags.insert(UnarchiverFlags.RequiresSecureCoding)
                }
            }
        }
    }
}

extension NSKeyedUnarchiver {
    @warn_unused_result
    public class func unarchiveTopLevelObjectWithData(data: NSData) throws -> AnyObject? {
        var root : AnyObject? = nil
        
        if let keyedUnarchiver = NSKeyedUnarchiver(forReadingWithData: data) {
            do {
                try root = keyedUnarchiver.decodeTopLevelObjectForKey(NSKeyedArchiveRootObjectKey)
                keyedUnarchiver.finishDecoding()
            } catch {
            }
        }
        
        return root
    }
}

public protocol NSKeyedUnarchiverDelegate : class {
    
    // Informs the delegate that the named class is not available during decoding.
    // The delegate may, for example, load some code to introduce the class to the
    // runtime and return it, or substitute a different class object.  If the
    // delegate returns nil, unarchiving aborts with an exception.  The first class
    // name string in the array is the class of the encoded object, the second is
    // the immediate superclass, and so on.
    func unarchiver(unarchiver: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String, originalClasses classNames: [String]) -> AnyClass?
    
    // Informs the delegate that the object has been decoded.  The delegate
    // either returns this object or can return a different object to replace
    // the decoded one.  The object may be nil.  If the delegate returns nil,
    // the decoded value will be unchanged (that is, the original object will be
    // decoded). The delegate may use this to keep track of the decoded objects.
    func unarchiver(unarchiver: NSKeyedUnarchiver, didDecodeObject object: AnyObject?) -> AnyObject?
    
    // Informs the delegate that the newObject is being substituted for the
    // object. This is also called when the delegate itself is doing/has done
    // the substitution. The delegate may use this method if it is keeping track
    // of the encoded or decoded objects.
    func unarchiver(unarchiver: NSKeyedUnarchiver, willReplaceObject object: AnyObject, withObject newObject: AnyObject)
    
    // Notifies the delegate that decoding is about to finish.
    func unarchiverWillFinish(unarchiver: NSKeyedUnarchiver)
    
    // Notifies the delegate that decoding has finished.
    func unarchiverDidFinish(unarchiver: NSKeyedUnarchiver)
}

extension NSKeyedUnarchiverDelegate {
    func unarchiver(unarchiver: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String, originalClasses classNames: [String]) -> AnyClass? {
        return nil
    }
    
    func unarchiver(unarchiver: NSKeyedUnarchiver, didDecodeObject object: AnyObject?) -> AnyObject? {
        // Returning the same object is the same as doing nothing
        return object
    }
    
    func unarchiver(unarchiver: NSKeyedUnarchiver, willReplaceObject object: AnyObject, withObject newObject: AnyObject) { }
    func unarchiverWillFinish(unarchiver: NSKeyedUnarchiver) { }
    func unarchiverDidFinish(unarchiver: NSKeyedUnarchiver) { }
}


// TODO: Could perhaps be an extension of NSCoding instead. The reason it is an extension of NSObject is the lack of default implementations on protocols in Objective-C.
extension NSObject {
    public class func classForKeyedUnarchiver() -> AnyClass {
        return self
    }
}
