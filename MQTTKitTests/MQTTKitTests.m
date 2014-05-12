//
//  MQTTKitTests.m
//  MQTTKitTests
//
//  Created by Jeff Mesnil on 22/10/2013.
//  Copyright (c) 2013 Jeff Mesnil. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "MQTTKit.h"

#define secondsToNanoseconds(t) (t * 1000000000ull) // in nanoseconds
#define gotSignal(semaphore, timeout) ((dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, secondsToNanoseconds(timeout)))) == 0l)

#define kTimeoutForSuccess 30
#define kTimeoutForFailure 30

#define M2M 1

#if M2M

#define kHost @"m2m.eclipse.org"
#define kPort 1883

#else

#define kHost @"localhost"
#define kPort 1883

#endif

@interface MQTTKitTests : XCTestCase

@end

@implementation MQTTKitTests

MQTTClient *client;
NSString *topic;

- (void)setUp
{
    [super setUp];

    client = [[MQTTClient alloc] initWithClientId:@"MQTTKitTests"];
    client.host = kHost;
    client.port = kPort;
    
    topic = [NSString stringWithFormat:@"MQTTKitTests/%@", [[NSUUID UUID] UUIDString]];
}

- (void)tearDown
{
    [client disconnectWithCompletionHandler:nil];

#ifdef M2M
    [self deleteTopic:topic];
#endif

    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)deleteTopic:(NSString *)topic
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
    request.URL = [NSURL URLWithString:[NSString stringWithFormat:@"http://eclipse.mqttbridge.com/%@",
                                        [topic stringByReplacingOccurrencesOfString:@"/"
                                                                         withString:@"%2F"]]];
    request.HTTPMethod = @"DELETE";
    
    NSHTTPURLResponse *response;
    NSError *error;
    NSLog(@"DELETE %@", request.URL);
    [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    if (error) {
        XCTFail(@"%@", error);
    }
    XCTAssertEqual((NSInteger)200, response.statusCode);
}

- (void)testConnectOnUnknownServer
{
    dispatch_semaphore_t connectError = dispatch_semaphore_create(0);

    client.host = @"this.is.not.a.mqtt.server";

    [client connectWithCompletionHandler:^(MQTTConnectionReturnCode code) {
        if (code == ConnectionRefusedServerUnavailable) {
            dispatch_semaphore_signal(connectError);
        }
    }];

    XCTAssertFalse(gotSignal(connectError, kTimeoutForFailure));
}

- (void)testConnectDisconnect
{
    dispatch_semaphore_t connected = dispatch_semaphore_create(0);
    
    client.reconnectDelay = 1;
    client.reconnectDelayMax = 10;
    client.reconnectExponentialBackoff = YES;
    
    [client connectWithCompletionHandler:^(MQTTConnectionReturnCode code) {
        if (code == ConnectionAccepted) {
            dispatch_semaphore_signal(connected);
        }
    }];

    XCTAssertTrue(gotSignal(connected, kTimeoutForSuccess));

    dispatch_semaphore_t disconnected = dispatch_semaphore_create(0);

    [client disconnectWithCompletionHandler:^(NSUInteger code) {
        dispatch_semaphore_signal(disconnected);
    }];

    XCTAssertTrue(gotSignal(disconnected, kTimeoutForSuccess));
}

- (void)publishWithClient:(MQTTClient *)client
{
    dispatch_semaphore_t subscribed = dispatch_semaphore_create(0);

    [client connectWithCompletionHandler:^(NSUInteger code) {
        [client subscribe:topic
                  withQos:AtMostOnce
        completionHandler:^(NSArray *grantedQos) {
            for (NSNumber *qos in grantedQos) {
                NSLog(@"%@", qos);
            }
            dispatch_semaphore_signal(subscribed);
        }];
    }];

    XCTAssertTrue(gotSignal(subscribed, kTimeoutForSuccess));

    NSString *text = [NSString stringWithFormat:@"Hello, MQTT %d", arc4random()];

    dispatch_semaphore_t received = dispatch_semaphore_create(0);

    [client setMessageHandler:^(MQTTMessage *message) {
        XCTAssertTrue([text isEqualToString:message.payloadString]);
        dispatch_semaphore_signal(received);
    }];

    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    [client publishString:text toTopic:topic
                  withQos:AtMostOnce
                   retain:YES
        completionHandler:^(int mid) {
            dispatch_semaphore_signal(published);
        }];

    XCTAssertTrue(gotSignal(published, kTimeoutForSuccess));

    XCTAssertTrue(gotSignal(received, kTimeoutForSuccess));

    [client disconnectWithCompletionHandler:nil];
}

- (void)testPublish
{
    [self publishWithClient:client];
}

- (void)testPublishMany
{
    dispatch_semaphore_t subscribed = dispatch_semaphore_create(0);
    
    [client connectWithCompletionHandler:^(NSUInteger code) {
        [client subscribe:topic
                  withQos:AtMostOnce
        completionHandler:^(NSArray *grantedQos) {
            dispatch_semaphore_signal(subscribed);
        }];
    }];
    
    XCTAssertTrue(gotSignal(subscribed, kTimeoutForSuccess));
    
    NSString *text = [NSString stringWithFormat:@"Hello, MQTT %d", arc4random()];
    
    int count = 10;
    for (int i = 0; i < count; i++) {
        [client publishString:text
                      toTopic:topic
                      withQos:AtMostOnce
                       retain:NO
            completionHandler:^(int mid) {
                NSLog(@"published message %i", mid);
        }];
    }
    
    dispatch_semaphore_t received = dispatch_semaphore_create(0);

    __block int receivedCount = 0;
    [client setMessageHandler:^(MQTTMessage *message) {
        NSLog(@"received message");
        XCTAssertTrue([text isEqualToString:message.payloadString]);
        receivedCount++;
        if (receivedCount == count) {
            dispatch_semaphore_signal(received);
        }
    }];
    
    XCTAssertTrue(gotSignal(received, kTimeoutForSuccess));

    [client disconnectWithCompletionHandler:nil];
}

/*
 * use test.mosquitto.org to check TLS support
 *
 * the test will download the CA certificate from the test.mosquitto.org web site
 */
- (void)testPublishWithTLS
{
    client.host = @"test.mosquitto.org";
    client.port = 8883;

    NSURL *url = [NSURL URLWithString:@"http://test.mosquitto.org/ssl/mosquitto.org.crt"];
    NSData *content = [[NSData alloc] initWithContentsOfURL:url];
    NSString *cafile = @"/tmp/mosquitto.org.crt";
    [content writeToFile:cafile atomically:YES];
    client.cafile = cafile;

    [self publishWithClient:client];
}

- (void)testUnsubscribe
{
    dispatch_semaphore_t subscribed = dispatch_semaphore_create(0);

    [client connectWithCompletionHandler:^(NSUInteger code) {
        [client subscribe:topic
                  withQos:AtMostOnce
        completionHandler:^(NSArray *grantedQos) {
             dispatch_semaphore_signal(subscribed);
         }];
    }];

    XCTAssertTrue(gotSignal(subscribed, kTimeoutForSuccess));

    NSString *text = [NSString stringWithFormat:@"Hello, MQTT %d", arc4random()];

    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    
    [client setMessageHandler:^(MQTTMessage *message) {
        XCTAssertTrue([text isEqualToString:message.payloadString]);
        dispatch_semaphore_signal(received);
    }];
    
    dispatch_semaphore_t unsubscribed = dispatch_semaphore_create(0);

    [client unsubscribe:topic withCompletionHandler:^{
        dispatch_semaphore_signal(unsubscribed);
    }];

    XCTAssertTrue(gotSignal(unsubscribed, kTimeoutForSuccess));

    dispatch_semaphore_t published = dispatch_semaphore_create(0);

    [client publishString:text
                  toTopic:topic
                  withQos:AtMostOnce
                   retain:NO
        completionHandler:^(int mid) {
        dispatch_semaphore_signal(published);
    }];

    XCTAssertTrue(gotSignal(published, kTimeoutForSuccess));

    XCTAssertFalse(gotSignal(received, kTimeoutForFailure));

    [client disconnectWithCompletionHandler:nil];
}

@end
