#include <mbgl/storage/http_file_source.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/storage/response.hpp>

#include <mbgl/util/client_options.hpp>
#include <mbgl/util/http_header.hpp>
#include <mbgl/util/async_task.hpp>
#include <mbgl/util/async_request.hpp>
#include <mbgl/util/version.hpp>

#import <Foundation/Foundation.h>

#include <mbgl/interface/native_apple_interface.h>

#include <mutex>
#include <chrono>

@interface MBGLBundleCanary : NSObject
@end

@implementation MBGLBundleCanary
@end

namespace mbgl {

// Data that is shared between the requesting thread and the thread running the completion handler.
class HTTPRequestShared {
public:
    HTTPRequestShared(Response& response_, util::AsyncTask& async_)
        : response(response_),
          async(async_) {
    }

    void notify(const Response& response_) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!cancelled) {
            response = response_;
            async.send();
        }
    }

    void cancel() {
        std::lock_guard<std::mutex> lock(mutex);
        cancelled = true;
    }

private:
    std::mutex mutex;
    bool cancelled = false;

    Response& response;
    util::AsyncTask& async;
};

class HTTPRequest : public AsyncRequest {
public:
    HTTPRequest(FileSource::Callback callback_)
        : shared(std::make_shared<HTTPRequestShared>(response, async)),
          callback(callback_) {
    }

    ~HTTPRequest() override {
        shared->cancel();
        if (task) {
            [task cancel];
        }
    }

    std::shared_ptr<HTTPRequestShared> shared;
    NSURLSessionDataTask* task = nil;

private:
    FileSource::Callback callback;
    Response response;

    util::AsyncTask async { [this] {
        // Calling `callback` may result in deleting `this`. Copy data to temporaries first.
        auto callback_ = callback;
        auto response_ = response;
        callback_(response_);
    } };
};

class HTTPFileSource::Impl {
public:
    Impl(const ResourceOptions& resourceOptions_, const ClientOptions& clientOptions_)
        : resourceOptions(resourceOptions_.clone()), clientOptions(clientOptions_.clone()) {
            NSURLSessionConfiguration *sessionConfig = MLNNativeNetworkManager.sharedManager.sessionConfiguration;
            session = [NSURLSession sessionWithConfiguration:sessionConfig];

            if (sessionConfig.HTTPAdditionalHeaders[@"User-Agent"] == nil) {
                userAgent = getUserAgent();
            } else {
                userAgent = sessionConfig.HTTPAdditionalHeaders[@"User-Agent"];
            }
    }

    void setResourceOptions(ResourceOptions options);
    ResourceOptions getResourceOptions();

    void setClientOptions(ClientOptions options);
    ClientOptions getClientOptions();

    NSURLSession* session = nil;
    NSString* userAgent = nil;

private:
    NSString* getUserAgent() const;
    NSBundle* getSDKBundle() const;
    ResourceOptions resourceOptions;
    ClientOptions clientOptions;
};

void HTTPFileSource::Impl::setResourceOptions(ResourceOptions options) {
    resourceOptions = options;
}

ResourceOptions HTTPFileSource::Impl::getResourceOptions() {
    return resourceOptions.clone();
}

void HTTPFileSource::Impl::setClientOptions(ClientOptions options) {
    clientOptions = options;
}

ClientOptions HTTPFileSource::Impl::getClientOptions() {
    return clientOptions.clone();
}

NSString *HTTPFileSource::Impl::getUserAgent() const {
    NSMutableArray *userAgentComponents = [NSMutableArray array];

    NSBundle *appBundle = [NSBundle mainBundle];
    if (appBundle) {
        NSString *appName = appBundle.infoDictionary[@"CFBundleName"];
        [userAgentComponents addObject:[NSString stringWithFormat:@"%@/%@",
                                        appName.length ? appName : appBundle.infoDictionary[@"CFBundleIdentifier"],
                                        appBundle.infoDictionary[@"CFBundleShortVersionString"]]];
    } else {
        [userAgentComponents addObject:[NSProcessInfo processInfo].processName];
    }

    NSBundle *sdkBundle = HTTPFileSource::Impl::getSDKBundle();
    if (sdkBundle) {
        NSString *versionString = sdkBundle.infoDictionary[@"CFBundleShortVersionString"];
        if (versionString) {
            [userAgentComponents addObject:[NSString stringWithFormat:@"%@/%@",
                                            sdkBundle.infoDictionary[@"CFBundleName"], versionString]];
        }
    }

    // Avoid %s here because it inserts hidden bidirectional markers on macOS when the system
    // language is set to a right-to-left language.
    [userAgentComponents addObject:[NSString stringWithFormat:@"MapLibreNative/0.0.0 (%@)",
                                    @(mbgl::version::revision)]];

    NSString *systemName = @"Darwin";
#if TARGET_OS_IPHONE
    systemName = @"iOS";
#elif TARGET_OS_MAC
    systemName = @"macOS";
#elif TARGET_OS_WATCH
    systemName = @"watchOS";
#elif TARGET_OS_TV
    systemName = @"tvOS";
#endif
#if TARGET_OS_SIMULATOR
    systemName = [systemName stringByAppendingString:@" Simulator"];
#endif
    NSString *systemVersion = nil;
    if ([NSProcessInfo instancesRespondToSelector:@selector(operatingSystemVersion)]) {
        NSOperatingSystemVersion osVersion = [NSProcessInfo processInfo].operatingSystemVersion;
        systemVersion = [NSString stringWithFormat:@"%ld.%ld.%ld",
                         (long)osVersion.majorVersion, (long)osVersion.minorVersion, (long)osVersion.patchVersion];
    }
    if (systemVersion) {
        [userAgentComponents addObject:[NSString stringWithFormat:@"%@/%@", systemName, systemVersion]];
    }

    NSString *cpu = nil;
#if TARGET_CPU_X86
    cpu = @"x86";
#elif TARGET_CPU_X86_64
    cpu = @"x86_64";
#elif TARGET_CPU_ARM
    cpu = @"arm";
#elif TARGET_CPU_ARM64
    cpu = @"arm64";
#endif
    if (cpu) {
        [userAgentComponents addObject:[NSString stringWithFormat:@"(%@)", cpu]];
    }

    return [userAgentComponents componentsJoinedByString:@" "];
}

NSBundle *HTTPFileSource::Impl::getSDKBundle() const {
    NSBundle *bundle = [NSBundle bundleForClass:[MBGLBundleCanary class]];
    if (bundle && ![bundle.infoDictionary[@"CFBundlePackageType"] isEqualToString:@"FMWK"]) {
        // For static frameworks, the class is contained in the application bundle rather than the
        // framework bundle.
        bundle = [NSBundle bundleWithPath:[bundle.privateFrameworksPath
                                           stringByAppendingPathComponent:@"Mapbox.framework"]];
    }
    return bundle;
}

HTTPFileSource::HTTPFileSource(const ResourceOptions& resourceOptions, const ClientOptions& clientOptions)
    : impl(std::make_unique<Impl>(resourceOptions, clientOptions)) {
}

HTTPFileSource::~HTTPFileSource() = default;

MLN_APPLE_EXPORT
BOOL isValidMapboxEndpoint(NSURL *url) {
    return ([url.host isEqualToString:@"mapbox.com"] ||
            [url.host hasSuffix:@".mapbox.com"] ||
            [url.host isEqualToString:@"mapbox.cn"] ||
            [url.host hasSuffix:@".mapbox.cn"]);
}

MLN_APPLE_EXPORT
NSURL *resourceURL(const Resource& resource) {

    NSURL *url = [NSURL URLWithString:@(resource.url.c_str())];

#if TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
    if (isValidMapboxEndpoint(url)) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSMutableArray *queryItems = [NSMutableArray array];

        if (resource.usage == Resource::Usage::Offline) {
            [queryItems addObject:[NSURLQueryItem queryItemWithName:@"offline" value:@"true"]];
        }

        if (components.queryItems) {
            [queryItems addObjectsFromArray:components.queryItems];
        }

        components.queryItems = queryItems;
        url = components.URL;
    }
#endif
    return url;
}

std::unique_ptr<AsyncRequest> HTTPFileSource::request(const Resource& resource, std::function<void(Response)> callback) {
    auto request = std::make_unique<HTTPRequest>(std::move(callback));
    auto shared = request->shared; // Explicit copy so that it also gets copied into the completion handler block below.

    @autoreleasepool {
        NSURL *url = resourceURL(resource);
        [MLNNativeNetworkManager.sharedManager debugLog:@"Requesting URI: %@", url.relativePath];

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        if (resource.priorEtag) {
            [req addValue:@(resource.priorEtag->c_str())
                 forHTTPHeaderField:@"If-None-Match"];
        } else if (resource.priorModified) {
            [req addValue:@(util::rfc1123(*resource.priorModified).c_str())
                 forHTTPHeaderField:@"If-Modified-Since"];
        }

        if (resource.dataRange) {
            NSString *rangeHeader = [NSString stringWithFormat:@"bytes=%lld-%lld",
                                     static_cast<long long>(resource.dataRange->first),
                                     static_cast<long long>(resource.dataRange->second)];
            [req setValue:rangeHeader forHTTPHeaderField:@"Range"];
        }

        [req addValue:impl->userAgent forHTTPHeaderField:@"User-Agent"];

        const bool isTile = resource.kind == mbgl::Resource::Kind::Tile;

        if (isTile) {
            [MLNNativeNetworkManager.sharedManager startDownloadEvent:url.relativePath type:@"tile"];
        }

        __block NSURLSession *session = nil;

        // Use the delegate's session if there is one, otherwise use the one that
        // was created when this class was constructed.
        MLNNativeNetworkManager *networkManager = MLNNativeNetworkManager.sharedManager;
        if ([networkManager.delegate respondsToSelector:@selector(sessionForNetworkManager:)]) {
            session = [networkManager.delegate sessionForNetworkManager:networkManager];
        }

        if (!session) {
            session = impl->session;
        }

        assert(session);

        request->task = [session
            dataTaskWithRequest:req
              completionHandler:^(NSData* data, NSURLResponse* res, NSError* error) {
                session = nil;

                if (error && [error code] == NSURLErrorCancelled) {
                    [MLNNativeNetworkManager.sharedManager cancelDownloadEventForResponse:res];
                    return;
                }
                [MLNNativeNetworkManager.sharedManager stopDownloadEventForResponse:res];
                Response response;
                using Error = Response::Error;

                std::string stringResourceURL = " - Resource URL: " + resource.url;

                if (error) {
                    [MLNNativeNetworkManager.sharedManager errorLog:@"Requesting: %@ failed with error: %@", req.URL, error.debugDescription];

                    if (data) {
                        response.data =
                            std::make_shared<std::string>((const char*)[data bytes], [data length]);
                    }

                    switch ([error code]) {
                    case NSURLErrorBadServerResponse: // 5xx errors
                        response.error = std::make_unique<Error>(
                                                                 Error::Reason::Server, std::string{ [[error localizedDescription] UTF8String]} + stringResourceURL);

                        break;

                    case NSURLErrorNetworkConnectionLost:
                    case NSURLErrorCannotFindHost:
                    case NSURLErrorCannotConnectToHost:
                    case NSURLErrorDNSLookupFailed:
                    case NSURLErrorNotConnectedToInternet:
                    case NSURLErrorInternationalRoamingOff:
                    case NSURLErrorCallIsActive:
                    case NSURLErrorDataNotAllowed:
                    case NSURLErrorTimedOut:
                        response.error = std::make_unique<Error>(
                            Error::Reason::Connection, [[error localizedDescription] UTF8String] + stringResourceURL);
                        break;

                    default:
                        response.error = std::make_unique<Error>(
                            Error::Reason::Other, [[error localizedDescription] UTF8String] + stringResourceURL);
                        break;
                    }
                } else if ([res isKindOfClass:[NSHTTPURLResponse class]]) {
                    const long responseCode = [(NSHTTPURLResponse *)res statusCode];
                    [MLNNativeNetworkManager.sharedManager debugLog:@"Requesting %@ returned responseCode: %lu", res.URL.relativePath, responseCode];

                    NSDictionary *headers = [(NSHTTPURLResponse *)res allHeaderFields];
                    NSString *cache_control = [headers objectForKey:@"Cache-Control"];
                    if (cache_control) {
                        const auto cc = http::CacheControl::parse([cache_control UTF8String]);
                        response.expires = cc.toTimePoint();
                        response.mustRevalidate = cc.mustRevalidate;
                    }

                    NSString *expires = [headers objectForKey:@"Expires"];
                    if (expires) {
                        response.expires = util::parseTimestamp([expires UTF8String]);
                    }

                    NSString *last_modified = [headers objectForKey:@"Last-Modified"];
                    if (last_modified) {
                        response.modified = util::parseTimestamp([last_modified UTF8String]);
                    }

                    NSString *etag = [headers objectForKey:@"ETag"];
                    if (etag) {
                        response.etag = std::string([etag UTF8String]);
                    }

                    if (responseCode == 200 || responseCode == 206) {
                        response.data = std::make_shared<std::string>((const char *)[data bytes], [data length]);
                    } else if (responseCode == 204 || (responseCode == 404 && isTile)) {
                        response.noContent = true;
                    } else if (responseCode == 304) {
                        response.notModified = true;
                    } else if (responseCode == 404) {
                        response.error =
                            std::make_unique<Error>(Error::Reason::NotFound, "HTTP status code 404" + stringResourceURL);
                    } else if (responseCode == 429) {
                        // Get the standard header
                        std::optional<std::string> retryAfter;
                        NSString *retryAfterHeader = headers[@"Retry-After"];
                        if (retryAfterHeader) {
                            retryAfter = std::string([retryAfterHeader UTF8String]);
                        }

                        // Fallback mapbox specific header
                        std::optional<std::string> xRateLimitReset;
                        NSString *xReset = headers[@"x-rate-limit-reset"];
                        if (xReset) {
                            xRateLimitReset = std::string([xReset UTF8String]);
                        }

                        response.error = std::make_unique<Error>(Error::Reason::RateLimit, "HTTP status code 429" + stringResourceURL, http::parseRetryHeaders(retryAfter, xRateLimitReset));
                    } else if (responseCode >= 500 && responseCode < 600) {
                        response.error =
                            std::make_unique<Error>(Error::Reason::Server, std::string{ "HTTP status code " } +
                                                                               std::to_string(responseCode) + stringResourceURL);
                    } else {
                        response.error =
                            std::make_unique<Error>(Error::Reason::Other, std::string{ "HTTP status code " } +
                                                                              std::to_string(responseCode) + stringResourceURL);
                    }
                } else if ([url isFileURL]) {
                    response.data = std::make_shared<std::string>((const char *)[data bytes], [data length]);
                } else {
                    // This should never happen.
                    response.error = std::make_unique<Error>(Error::Reason::Other,
                                                              "Response class is not NSHTTPURLResponse" + stringResourceURL);
                }

                shared->notify(response);
            }];

        [request->task resume];
    }

    return std::move(request);
}

void HTTPFileSource::setResourceOptions(ResourceOptions options) {
    impl->setResourceOptions(options.clone());
}

ResourceOptions HTTPFileSource::getResourceOptions() {
    return impl->getResourceOptions();
}

void HTTPFileSource::setClientOptions(ClientOptions options) {
    impl->setClientOptions(options.clone());
}

ClientOptions HTTPFileSource::getClientOptions() {
    return impl->getClientOptions();
}
}
