// The MIT License (MIT)
//
// Copyright (c) 2015 Alexander Grebenyuk (github.com/kean).

import Foundation

// MARK: - ImageLoading

/** Performs the actual loading of images for the image tasks.

In most cases you would not need to use this protocol to customize image loading. See ImageDataLoading, ImageProcessing and ImageDecoding protocols instead.
*/
public protocol ImageLoading: class {
    weak var manager: ImageLoadingManager? { get set }
    func resumeLoadingForTask(task: ImageTask)
    func suspendLoadingForTask(task: ImageTask)
    func cancelLoadingForTask(task: ImageTask)
    func isRequestCacheEquivalent(lhs: ImageRequest, toRequest rhs: ImageRequest) -> Bool
    func invalidate()
    func removeAllCachedImages()
}

// MARK: - ImageLoadingDelegate

/** Manages image loading.
*/
public protocol ImageLoadingManager: class {
    func imageLoader(imageLoader: ImageLoading, task: ImageTask, didUpdateProgressWithCompletedUnitCount completedUnitCount: Int64, totalUnitCount: Int64)
    func imageLoader(imageLoader: ImageLoading, task: ImageTask, didCompleteWithImage image: Image?, error: ErrorType?, userInfo: Any?)
}

// MARK: - ImageLoaderConfiguration

public struct ImageLoaderConfiguration {
    public var dataLoader: ImageDataLoading
    public var decoder: ImageDecoding
    
    /** Image decoding queue. See `ImageDecoding` protocol for more info.
     */
    public var decodingQueue = NSOperationQueue(maxConcurrentOperationCount: 1)
    
    /** Image processing queue. See `ImageProcessing` protocol for more info.
     */
    public var processingQueue = NSOperationQueue(maxConcurrentOperationCount: 2)
    
    /**
     Initializes configuration with data loader and image decoder.
     
     - parameter dataLoader: Image data loader.
     - parameter decoder: Image decoder. Default `ImageDecoder` instance is created if the parameter is omitted.
     */
    public init(dataLoader: ImageDataLoading, decoder: ImageDecoding = ImageDecoder()) {
        self.dataLoader = dataLoader
        self.decoder = decoder
    }
}

// MARK: - ImageLoaderDelegate

/** Image loader customization endpoint.
*/
public protocol ImageLoaderDelegate {
    /** Compares two requests for equivalence with regard to loading image data. Requests should be considered equivalent if data loader can handle both requests with a single session task.
     */
    func isEquivalentForLoading(lhs: ImageRequest, to rhs: ImageRequest) -> Bool
    
    /** Compares two requests for equivalence with regard to caching output image. This method is used for memory caching only, which means that there is no need for filtering out the dynamic part of the request (is there is any).
     */
    func isEquivalentForCaching(lhs: ImageRequest, to rhs: ImageRequest) -> Bool
    
    /** Returns true when image loader should process the image. Processing includes decompression.
     */
    func imageLoader(loader: ImageLoader, shouldProcessImage image: Image) -> Bool
    
    /** Returns decompressor for the given request. 
     */
    func imageLoader(loader: ImageLoader, decompressorForRequest request: ImageRequest) -> ImageProcessing?
}

public extension ImageLoaderDelegate {
    /** Determines whether two image request can be handled by a single `NSURLSessionTask`. Default implementation compares request `URL`, `cachePolicy`, `timeoutInterval`, `networkServiceType` and `allowsCellularAccess`.
    */
    public func isEquivalentForLoading(lhs: ImageRequest, to rhs: ImageRequest) -> Bool {
        let a = lhs.URLRequest, b = rhs.URLRequest
        return a.URL == b.URL &&
            a.cachePolicy == b.cachePolicy &&
            a.timeoutInterval == b.timeoutInterval &&
            a.networkServiceType == b.networkServiceType &&
            a.allowsCellularAccess == b.allowsCellularAccess
    }
    
    /** Determines whether two image requests return the same image data. Default implementation compares request `URLs`. This method doesn't compare requests in terms of image processing.
     */
    public func isEquivalentForCaching(lhs: ImageRequest, to rhs: ImageRequest) -> Bool {
        return lhs.URLRequest.URL == rhs.URLRequest.URL
    }
    
    /** Always returns true.
     */
    public func imageLoader(loader: ImageLoader, shouldProcessImage image: Image) -> Bool {
        return true
    }
    
    /** Returns instance of `ImageDecompressor` class (expect for OS X where this class is not available).
     */
    public func imageLoader(loader: ImageLoader, decompressorForRequest request: ImageRequest) -> ImageProcessing? {
        #if os(OSX)
            return nil
        #else
            return ImageDecompressor(targetSize: request.targetSize, contentMode: request.contentMode)
        #endif
    }
}

public class ImageLoaderDefaultDelegate: ImageLoaderDelegate {
    public init() {}
}

// MARK: - ImageLoader

/**
Performs the actual loading of images for the image tasks using objects conforming to `ImageDataLoading`, `ImageDecoding` and `ImageProcessing` protocols. Works in conjunction with the `ImageManager`.

- Provides a transparent loading, decoding and processing with a single completion signal
- Reuses data tasks for multiple equivalent image tasks
- Offloads work to the background queue
*/
public class ImageLoader: ImageLoading {
    public weak var manager: ImageLoadingManager?
    public let configuration: ImageLoaderConfiguration
    public let delegate: ImageLoaderDelegate
    
    private var dataLoader: ImageDataLoading {
        return self.configuration.dataLoader
    }
    private var executingTasks = [ImageTask : ImageLoadState]()
    private var sessionTasks = [ImageRequestKey : ImageSessionTask]()
    private let queue = dispatch_queue_create("ImageLoader-InternalSerialQueue", DISPATCH_QUEUE_SERIAL)
    
    /**
     Initializes image loader with a configuration and a delegate.
     
     - parameter delegate: Instance of `ImageLoaderDefaultDelegate` created if the parameter is omitted.
     */
    public init(configuration: ImageLoaderConfiguration, delegate: ImageLoaderDelegate = ImageLoaderDefaultDelegate()) {
        self.configuration = configuration
        self.delegate = delegate
    }
    
    public func resumeLoadingForTask(task: ImageTask) {
        dispatch_async(self.queue) {
            let key = ImageRequestKey(task.request, owner: self)
            var sessionTask: ImageSessionTask! = self.sessionTasks[key]
            if sessionTask == nil {
                sessionTask = self.createSessionTaskWithRequest(task.request, key: key)
                self.sessionTasks[key] = sessionTask
            } else {
                self.manager?.imageLoader(self, task: task, didUpdateProgressWithCompletedUnitCount: sessionTask.completedUnitCount, totalUnitCount: sessionTask.totalUnitCount)
            }
            self.executingTasks[task] = ImageLoadState.Loading(sessionTask)
            sessionTask.resumeWith(task)
        }
    }

    private func createSessionTaskWithRequest(request: ImageRequest, key: ImageRequestKey) -> ImageSessionTask {
        let sessionTask = ImageSessionTask(key: key)
        let dataTask = self.dataLoader.imageDataTaskWithRequest(request, progressHandler: { [weak self] completedUnits, totalUnits in
            self?.sessionTask(sessionTask, didUpdateProgressWithCompletedUnitCount: completedUnits, totalUnitCount: totalUnits)
        }, completionHandler: { [weak self] data, response, error in
            self?.sessionTask(sessionTask, didCompleteWithData: data, response: response, error: error)
        })
        sessionTask.dataTask = dataTask
        return sessionTask
    }

    private func sessionTask(sessionTask: ImageSessionTask, didUpdateProgressWithCompletedUnitCount completedUnitCount: Int64, totalUnitCount: Int64) {
        dispatch_async(self.queue) {
            sessionTask.totalUnitCount = totalUnitCount
            sessionTask.completedUnitCount = completedUnitCount
            for imageTask in sessionTask.tasks {
                self.manager?.imageLoader(self, task: imageTask, didUpdateProgressWithCompletedUnitCount: completedUnitCount, totalUnitCount: totalUnitCount)
            }
        }
    }

    private func sessionTask(sessionTask: ImageSessionTask, didCompleteWithData data: NSData?, response: NSURLResponse?, error: ErrorType?) {
        guard let data = data where error == nil else {
            self.sessionTask(sessionTask, didCompleteWithImage: nil, error: error)
            return;
        }
        self.configuration.decodingQueue.addOperationWithBlock { [weak self] in
            let image = self?.configuration.decoder.imageWithData(data)
            self?.sessionTask(sessionTask, didCompleteWithImage: image, error: error)
        }
    }

    private func sessionTask(sessionTask: ImageSessionTask, didCompleteWithImage image: Image?, error: ErrorType?) {
        dispatch_async(self.queue) {
            for imageTask in sessionTask.tasks {
                self.processImage(image, error: error, forImageTask: imageTask)
            }
            sessionTask.complete()
            self.removeSessionTask(sessionTask)
        }
    }
    
    private func processImage(image: Image?, error: ErrorType?, forImageTask imageTask: ImageTask) {
        if let image = image, processor = self.processorForRequest(imageTask.request) where self.delegate.imageLoader(self, shouldProcessImage: image) {
            let operation = NSBlockOperation { [weak self] in
                self?.imageTask(imageTask, didCompleteWithImage: processor.processImage(image), error: error)
            }
            self.configuration.processingQueue.addOperation(operation)
            self.executingTasks[imageTask] = ImageLoadState.Processing(operation)
        } else {
            self.imageTask(imageTask, didCompleteWithImage: image, error: error)
        }
    }
    
    private func processorForRequest(request: ImageRequest) -> ImageProcessing? {
        var processors = [ImageProcessing]()
        if request.shouldDecompressImage, let decompressor = self.delegate.imageLoader(self, decompressorForRequest: request) {
            processors.append(decompressor)
        }
        if let processor = request.processor {
            processors.append(processor)
        }
        return processors.isEmpty ? nil : ImageProcessorComposition(processors: processors)
    }
    
    private func imageTask(imageTask: ImageTask, didCompleteWithImage image: Image?, error: ErrorType?) {
        dispatch_async(self.queue) {
            self.manager?.imageLoader(self, task: imageTask, didCompleteWithImage: image, error: error, userInfo: nil)
            self.executingTasks[imageTask] = nil
        }
    }

    public func suspendLoadingForTask(task: ImageTask) {
        dispatch_async(self.queue) {
            if let state = self.executingTasks[task] {
                switch state {
                case .Loading(let sessionTask):
                    sessionTask.suspendWith(task)
                default: break
                }
            }
        }
    }
    
    public func cancelLoadingForTask(task: ImageTask) {
        dispatch_async(self.queue) {
            if let state = self.executingTasks[task] {
                switch state {
                case .Loading(let sessionTask):
                    if sessionTask.cancelWith(task) {
                        self.removeSessionTask(sessionTask)
                    }
                case .Processing(let operation):
                    operation.cancel()
                }
                self.executingTasks[task] = nil
            }
        }
    }
    
    private func removeSessionTask(task: ImageSessionTask) {
        if self.sessionTasks[task.key] === task {
            self.sessionTasks[task.key] = nil
        }
    }
    
    // MARK: Misc
    
    public func isRequestCacheEquivalent(lhs: ImageRequest, toRequest rhs: ImageRequest) -> Bool {
        guard self.delegate.isEquivalentForCaching(lhs, to: rhs) else {
            return false
        }
        return equivalentProcessors(self.processorForRequest(lhs), rhs: self.processorForRequest(rhs))
    }
    
    public func invalidate() {
        self.dataLoader.invalidate()
    }
    
    public func removeAllCachedImages() {
        self.dataLoader.removeAllCachedImages()
    }
}

// MARK: ImageLoader: ImageRequestKeyOwner

extension ImageLoader: ImageRequestKeyOwner {
    public func isEqual(lhs: ImageRequestKey, to rhs: ImageRequestKey) -> Bool {
        return self.delegate.isEquivalentForLoading(lhs.request, to: rhs.request)
    }
}

// MARK: - ImageLoadState

private enum ImageLoadState {
    case Loading(ImageSessionTask)
    case Processing(NSOperation)
}

// MARK: - ImageSessionTask

private class ImageSessionTask {
    let key: ImageRequestKey
    var dataTask: NSURLSessionTask?
    var executingTasks = Set<ImageTask>()
    var suspendedTasks = Set<ImageTask>()
    var tasks: Set<ImageTask> {
        return self.executingTasks.union(self.suspendedTasks)
    }
    var totalUnitCount: Int64 = 0
    var completedUnitCount: Int64 = 0
    
    init(key: ImageRequestKey) {
        self.key = key
    }
    
    func resumeWith(task: ImageTask) {
        self.suspendedTasks.remove(task)
        self.executingTasks.insert(task)
        self.dataTask?.resume()
    }
    
    func cancelWith(task: ImageTask) -> Bool {
        self.executingTasks.remove(task)
        self.suspendedTasks.remove(task)
        if self.tasks.isEmpty {
            self.dataTask?.cancel()
            self.dataTask = nil
            return true
        }
        return false
    }
    
    func suspendWith(task: ImageTask) {
        self.executingTasks.remove(task)
        self.suspendedTasks.insert(task)
        if self.executingTasks.isEmpty {
            self.dataTask?.suspend()
        }
    }
    
    func complete() {
        self.executingTasks.removeAll()
        self.suspendedTasks.removeAll()
        self.dataTask = nil
    }
}
