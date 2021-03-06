//
//  RoomViewController.m
//  OpenTokRTC
//
//  Copyright © 2016 TokBox, Inc. All rights reserved.
//

#import "RoomViewController.h"

// FIXME: so much hard-coding. use autolayout
#define APP_IN_FULL_SCREEN                 @"appInFullScreenMode"
#define PUBLISHER_BAR_HEIGHT               50.0f
#define SUBSCRIBER_BAR_HEIGHT              44.0f
#define ARCHIVE_BAR_HEIGHT                 35.0f
#define PUBLISHER_ARCHIVE_CONTAINER_HEIGHT 85.0f

#define PUBLISHER_PREVIEW_HEIGHT           87.0f
#define PUBLISHER_PREVIEW_WIDTH            113.0f

#define OVERLAY_HIDE_TIME                  7.0f

// FIXME: no global variables
NSString *kApiKey = @"";
NSString *kSessionId = @"";
// Replace with your generated token
NSString *kToken = @"";

// FIXME: put extensions into separate files, or, don't use them
// otherwise no upside down rotation
@interface UINavigationController (RotationAll)
- (NSUInteger)supportedInterfaceOrientations;
@end

@implementation UINavigationController (RotationAll)
- (NSUInteger)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end

@interface RoomViewController () <OTSessionDelegate, OTSubscriberKitDelegate, OTPublisherDelegate> {
    NSMutableDictionary *allStreams;
    NSMutableDictionary *allSubscribers;
    NSMutableArray *allConnectionsIds;
    NSMutableArray *backgroundConnectedStreams;

    // FIXME: use properties instead of explicitly defining backing ivars
    OTSession *_session;
    OTConnection *_otherConnection;
    OTPublisher *_publisher;
    OTSubscriber *_currentSubscriber;
    CGPoint _startPosition;

    BOOL initialized;
}

@end

@implementation RoomViewController

// FIXME: don't need to synthesize anymore
@synthesize videoContainerView;

// FIXME: this method is way too big, most of it should be storyboard stuff
- (void)viewDidLoad {
    [super viewDidLoad];

    [self.view sendSubviewToBack:self.videoContainerView];
    self.endCallButton.titleLabel.lineBreakMode = NSLineBreakByCharWrapping;
    self.endCallButton.titleLabel.textAlignment = NSTextAlignmentCenter;

    // Default no full screen
    [self.topOverlayView.layer setValue:[NSNumber numberWithBool:NO]
                                 forKey:APP_IN_FULL_SCREEN];

    self.audioPubUnpubButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin |
        UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;

    // Add right side border to camera toggle button
    CALayer *rightBorder = [CALayer layer];
    rightBorder.borderColor = [UIColor whiteColor].CGColor;
    rightBorder.borderWidth = 1;
    rightBorder.frame = CGRectMake(-1, -1, CGRectGetWidth(self.cameraToggleButton.frame),
                                   CGRectGetHeight(self.cameraToggleButton.frame) + 2);
    self.cameraToggleButton.clipsToBounds = YES;
    [self.cameraToggleButton.layer addSublayer:rightBorder];

    // Left side border to audio publish/unpublish button
    CALayer *leftBorder = [CALayer layer];
    leftBorder.borderColor = [UIColor whiteColor].CGColor;
    leftBorder.borderWidth = 1;
    leftBorder.frame = CGRectMake(-1, -1, CGRectGetWidth(self.audioPubUnpubButton.frame) + 5,
                                  CGRectGetHeight(self.audioPubUnpubButton.frame) + 2);
    [self.audioPubUnpubButton.layer addSublayer:leftBorder];

    // configure video container view
    videoContainerView.scrollEnabled = YES;
    videoContainerView.pagingEnabled = YES;
    videoContainerView.delegate = self;
    videoContainerView.showsHorizontalScrollIndicator = NO;
    videoContainerView.showsVerticalScrollIndicator = YES;
    videoContainerView.bounces = NO;
    videoContainerView.alwaysBounceHorizontal = NO;


    // initialize constants
    allStreams = [[NSMutableDictionary alloc] init];
    allSubscribers = [[NSMutableDictionary alloc] init];
    allConnectionsIds = [[NSMutableArray alloc] init];
    backgroundConnectedStreams = [[NSMutableArray alloc] init];


    // set up look of the page
    [self.navigationController setNavigationBarHidden:NO];

    self.navigationItem.hidesBackButton = YES;

    // listen to taps around the screen, and hide/show overlay views
    UITapGestureRecognizer *tgr = [[UITapGestureRecognizer alloc]
                                   initWithTarget:self
                                           action:@selector(viewTapped:)];
    tgr.delegate = self;
    [self.view addGestureRecognizer:tgr];

    UITapGestureRecognizer *leftArrowTapGesture = [[UITapGestureRecognizer alloc]
                                                   initWithTarget:self
                                                           action:@selector(handleArrowTap:)];
    leftArrowTapGesture.delegate = self;
    [self.leftArrowImgView addGestureRecognizer:leftArrowTapGesture];

    UITapGestureRecognizer *rightArrowTapGesture = [[UITapGestureRecognizer alloc]
                                                    initWithTarget:self
                                                            action:@selector(handleArrowTap:)];
    rightArrowTapGesture.delegate = self;
    [self.rightArrowImgView addGestureRecognizer:rightArrowTapGesture];

    [self resetArrowsStates];

    self.archiveOverlay.hidden = YES;

    self.title = self.rid;

    // FIXME: this should all be model logic
    NSString *roomInfoUrl = [[NSString alloc] initWithFormat:@"https://opentokrtc.com/%@.json", self.rid];
    NSURL *url = [NSURL URLWithString:roomInfoUrl];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                       timeoutInterval:10];
    [request setHTTPMethod:@"GET"];
    // FIXME: use NSURLSession
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        if (error) {
            // FIXME: do something user facing with this error
            NSLog(@"Error,%@, url : %@", [error localizedDescription], roomInfoUrl);
        } else {
            NSDictionary *roomInfo = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
            kApiKey = [roomInfo objectForKey:@"apiKey"];
            kToken = [roomInfo objectForKey:@"token"];
            kSessionId = [roomInfo objectForKey:@"sid"];
            [self setupSession];
            // FIXME: why?
            [self.endCallButton sendActionsForControlEvents:UIControlEventTouchDown];
        }
    }];

    // application background/foreground monitoring for publish/subscribe video toggling
    [[NSNotificationCenter defaultCenter]
     addObserver:self
        selector:@selector(enteringBackgroundMode:)
            name:UIApplicationWillResignActiveNotification
          object:nil];

    [[NSNotificationCenter defaultCenter]
     addObserver:self
        selector:@selector(leavingBackgroundMode:)
            name:UIApplicationDidBecomeActiveNotification
          object:nil];
}

- (void)enteringBackgroundMode:(NSNotification *)notification {
    _publisher.publishVideo = NO;
    _currentSubscriber.subscribeToVideo = NO;
}

- (void)leavingBackgroundMode:(NSNotification *)notification {
    _publisher.publishVideo = YES;
    _currentSubscriber.subscribeToVideo = YES;

    // now subscribe to any background connected streams
    // FIXME: do these subscribers get torn down when entering background mode?
    for (OTStream *stream in backgroundConnectedStreams) {
        // create subscriber
        OTSubscriber *subscriber = [[OTSubscriber alloc]
                                    initWithStream:stream delegate:self];
        // subscribe now
        OTError *error = nil;
        [_session subscribe:subscriber error:&error];

        if (error) {
            [self showAlert:[error localizedDescription]];
        }
    }

    [backgroundConnectedStreams removeAllObjects];
}

- (void)viewWillDisappear:(BOOL)animated {
    if ([self.navigationController.viewControllers indexOfObject:self] == NSNotFound) {
        // Navigation button was pressed. Do some stuff
        [self endCallAction:nil];
    }

    [super viewWillDisappear:animated];
}

- (void)viewWillAppear:(BOOL)animated {
    // if device starts in landscape mode
    [self willAnimateRotationToInterfaceOrientation:[[UIApplication sharedApplication] statusBarOrientation]
                                           duration:1.0];
    // FIXME: the order in which super is called is probably incorrect
    [super viewWillAppear:animated];
}

// FIXME: this should be a storyboard thing
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

// FIXME: this method is way too long
- (void)viewTapped:(UITapGestureRecognizer *)tgr {
    CGPoint location = [tgr locationInView:self.view];

    [self sendTapData:location];
    BOOL isInFullScreen = [[[self topOverlayView].layer valueForKey:APP_IN_FULL_SCREEN] boolValue];

    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];

    if (isInFullScreen) {
        [self.topOverlayView.layer setValue:[NSNumber numberWithBool:NO]
                                     forKey:APP_IN_FULL_SCREEN];

        // Show/Adjust top, bottom, archive, publisher and video container
        // views according to the orientation
        if (orientation == UIInterfaceOrientationPortrait ||
            orientation == UIInterfaceOrientationPortraitUpsideDown) {
            [UIView animateWithDuration:0.5 animations:^{
                CGRect frame = _currentSubscriber.view.frame;
                frame.size.height = self.videoContainerView.frame.size.height;
                _currentSubscriber.view.frame = frame;

                frame = self.topOverlayView.frame;
                frame.origin.y += frame.size.height;
                self.topOverlayView.frame = frame;

                frame = self.archiveOverlay.superview.frame;
                frame.origin.y -= frame.size.height;
                self.archiveOverlay.superview.frame = frame;

                [_publisher.view setFrame:CGRectMake(8,
                                                     self.view.frame.size.height - (PUBLISHER_BAR_HEIGHT + (self.archiveOverlay.hidden ? 0 : ARCHIVE_BAR_HEIGHT) + 8 + PUBLISHER_PREVIEW_HEIGHT),
                                                     PUBLISHER_PREVIEW_WIDTH,
                                                     PUBLISHER_PREVIEW_HEIGHT)];
            } completion:^(BOOL finished) {
                // FIXME: should probably do something here
            }];
        } else {
            [UIView animateWithDuration:0.5 animations:^{
                CGRect frame = _currentSubscriber.view.frame;
                frame.size.width = self.videoContainerView.frame.size.width;
                _currentSubscriber.view.frame = frame;

                frame = self.topOverlayView.frame;
                frame.origin.y += frame.size.height;
                self.topOverlayView.frame = frame;

                frame = self.bottomOverlayView.frame;

                if (orientation == UIInterfaceOrientationLandscapeRight) {
                    frame.origin.x -= frame.size.width;
                } else {
                    frame.origin.x += frame.size.width;
                }

                self.bottomOverlayView.frame = frame;

                frame = self.archiveOverlay.frame;
                frame.origin.y -= frame.size.height;
                self.archiveOverlay.frame = frame;

                if (orientation == UIInterfaceOrientationLandscapeRight) {
                    [_publisher.view setFrame:CGRectMake(8,
                                                         self.view.frame.size.height - ((self.archiveOverlay.hidden ? 0 : ARCHIVE_BAR_HEIGHT) + 8 + PUBLISHER_PREVIEW_HEIGHT),
                                                         PUBLISHER_PREVIEW_WIDTH,
                                                         PUBLISHER_PREVIEW_HEIGHT)];

                    self.rightArrowImgView.frame = CGRectMake(videoContainerView.frame.size.width - 40 - 10 - PUBLISHER_BAR_HEIGHT,
                                                              videoContainerView.frame.size.height / 2 - 20,
                                                              40,
                                                              40);
                } else {
                    [_publisher.view setFrame:CGRectMake(PUBLISHER_BAR_HEIGHT + 8,
                                                         self.view.frame.size.height - ((self.archiveOverlay.hidden ? 0 : ARCHIVE_BAR_HEIGHT) + 8 + PUBLISHER_PREVIEW_HEIGHT),
                                                         PUBLISHER_PREVIEW_WIDTH,
                                                         PUBLISHER_PREVIEW_HEIGHT)];

                    self.leftArrowImgView.frame = CGRectMake(10 + PUBLISHER_BAR_HEIGHT,
                                                             videoContainerView.frame.size.height / 2 - 20,
                                                             40,
                                                             40);
                }
            } completion:^(BOOL finished) {
                // FIXME: should probably do something here
            }];
        }

        // start overlay hide timer
        self.overlayTimer = [NSTimer scheduledTimerWithTimeInterval:OVERLAY_HIDE_TIME
                                                             target:self
                                                           selector:@selector(overlayTimerAction)
                                                           userInfo:nil
                                                            repeats:NO];
    } else {
        [self.topOverlayView.layer setValue:[NSNumber numberWithBool:YES]
                                     forKey:APP_IN_FULL_SCREEN];

        // invalidate timer so that it wont hide again
        [self.overlayTimer invalidate];

        // Hide/Adjust top, bottom, archive, publisher and video container
        // views according to the orientation
        if (orientation == UIInterfaceOrientationPortrait ||
            orientation == UIInterfaceOrientationPortraitUpsideDown) {
            [UIView animateWithDuration:0.5 animations:^{
                CGRect frame = _currentSubscriber.view.frame;

                // User really tapped (not from willAnimateToration...)
                if (tgr) {
                    frame.size.height = self.videoContainerView.frame.size.height;
                    _currentSubscriber.view.frame = frame;
                }

                frame = self.topOverlayView.frame;
                frame.origin.y -= frame.size.height;
                self.topOverlayView.frame = frame;

                frame = self.archiveOverlay.superview.frame;
                frame.origin.y += frame.size.height;
                self.archiveOverlay.superview.frame = frame;

                [_publisher.view setFrame:CGRectMake(8,
                                                     self.view.frame.size.height - (8 + PUBLISHER_PREVIEW_HEIGHT),
                                                     PUBLISHER_PREVIEW_WIDTH,
                                                     PUBLISHER_PREVIEW_HEIGHT)];
            } completion:^(BOOL finished) {
                // FIXME: should probably do something here
            }];
        } else {
            [UIView animateWithDuration:0.5 animations:^{
                CGRect frame = _currentSubscriber.view.frame;
                frame.size.width = self.videoContainerView.frame.size.width;
                _currentSubscriber.view.frame = frame;

                frame = self.topOverlayView.frame;
                frame.origin.y -= frame.size.height;
                self.topOverlayView.frame = frame;

                frame = self.bottomOverlayView.frame;

                if (orientation == UIInterfaceOrientationLandscapeRight) {
                    frame.origin.x += frame.size.width;

                    self.rightArrowImgView.frame = CGRectMake(videoContainerView.frame.size.width - 40 - 10,
                                                              videoContainerView.frame.size.height / 2 - 20,
                                                              40,
                                                              40);
                } else {
                    frame.origin.x -= frame.size.width;

                    self.leftArrowImgView.frame = CGRectMake(10,
                                                             videoContainerView.frame.size.height / 2 - 20,
                                                             40,
                                                             40);
                }

                self.bottomOverlayView.frame = frame;

                frame = self.archiveOverlay.frame;
                frame.origin.y += frame.size.height;
                self.archiveOverlay.frame = frame;


                [_publisher.view setFrame:CGRectMake(8,
                                                     self.view.frame.size.height - (8 + PUBLISHER_PREVIEW_HEIGHT),
                                                     PUBLISHER_PREVIEW_WIDTH,
                                                     PUBLISHER_PREVIEW_HEIGHT)];
            } completion:^(BOOL finished) {
                // FIXME: should probably do something here
            }];
        }
    }

    // no need to arrange subscribers when it comes from willRotate
    if (tgr) {
        [self reArrangeSubscribers];
    }

    [self resetArrowsStates];
}

- (void)overlayTimerAction {
    // FIXME: this is defined multiple times. factor it out
    BOOL isInFullScreen = [[[self topOverlayView].layer valueForKey:APP_IN_FULL_SCREEN] boolValue];

    // if any button is in highlighted state, we ignore hide action
    if (!self.cameraToggleButton.highlighted &&
        !self.audioPubUnpubButton.highlighted &&
        !self.audioPubUnpubButton.highlighted) {
        // Hide views
        if (!isInFullScreen) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // FIXME: why?
                [self viewTapped:[[self.view gestureRecognizers]
                                  objectAtIndex:0]];
            });
        }
    } else {
        // start the timer again for next time
        self.overlayTimer = [NSTimer scheduledTimerWithTimeInterval:OVERLAY_HIDE_TIME
                                                             target:self
                                                           selector:@selector(overlayTimerAction)
                                                           userInfo:nil
                                                            repeats:NO];
    }
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

// FIXME: method is way too long
// FIXME: way too much copy pasta
- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
                                         duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];

    // FIXME: again?
    BOOL isInFullScreen = [[[self topOverlayView].layer valueForKey:APP_IN_FULL_SCREEN] boolValue];

    // hide overlay views adjust positions based on orietnation and then
    // hide them again
    if (isInFullScreen) {
        // hide all bars to before rotate
        self.topOverlayView.hidden = YES;
        self.bottomOverlayView.hidden = YES;
    }

    NSUInteger connectionsCount = [allConnectionsIds count];
    UIInterfaceOrientation orientation = toInterfaceOrientation;

    // adjust overlay views
    if (orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown) {
        [videoContainerView setFrame:CGRectMake(0,
                                                0,
                                                self.view.frame.size.width,
                                                self.view.frame.size.height)];

        [_publisher.view setFrame:CGRectMake(8,
                                             self.view.frame.size.height - (isInFullScreen ? PUBLISHER_PREVIEW_HEIGHT + 8 : (PUBLISHER_BAR_HEIGHT + (self.archiveOverlay.hidden ? 0 : ARCHIVE_BAR_HEIGHT) + 8 + PUBLISHER_PREVIEW_HEIGHT)),
                                             PUBLISHER_PREVIEW_WIDTH,
                                             PUBLISHER_PREVIEW_HEIGHT)];

        UIView *containerView = self.archiveOverlay.superview;
        containerView.frame = CGRectMake(0,
                                         self.view.frame.size.height - PUBLISHER_ARCHIVE_CONTAINER_HEIGHT,
                                         self.view.frame.size.width,
                                         PUBLISHER_ARCHIVE_CONTAINER_HEIGHT);

        [self.bottomOverlayView removeFromSuperview];
        [containerView addSubview:self.bottomOverlayView];

        self.bottomOverlayView.frame = CGRectMake(0,
                                                  containerView.frame.size.height - PUBLISHER_BAR_HEIGHT,
                                                  containerView.frame.size.width,
                                                  PUBLISHER_BAR_HEIGHT);

        // Archiving overlay
        self.archiveOverlay.frame = CGRectMake(0,
                                               0,
                                               self.view.frame.size.width,
                                               ARCHIVE_BAR_HEIGHT);

        self.topOverlayView.frame = CGRectMake(0,
                                               0,
                                               self.view.frame.size.width,
                                               self.topOverlayView.frame.size.height);

        // Camera button
        self.cameraToggleButton.frame = CGRectMake(0, 0, 90, PUBLISHER_BAR_HEIGHT);

        //adjust border layer
        CALayer *borderLayer = nil;

        if ([[self.cameraToggleButton.layer sublayers] count] > 1) {
            borderLayer = [[self.cameraToggleButton.layer sublayers] objectAtIndex:1];
        } else {
            borderLayer = [[self.cameraToggleButton.layer sublayers] objectAtIndex:0];
        }

        borderLayer.frame = CGRectMake(-1,
                                       -1,
                                       CGRectGetWidth(_cameraToggleButton.frame),
                                       CGRectGetHeight(_cameraToggleButton.frame) + 2);

        // adjust call button
        self.endCallButton.frame = CGRectMake((self.bottomOverlayView.frame.size.width / 2) - (140 / 2),
                                              0,
                                              140,
                                              PUBLISHER_BAR_HEIGHT);

        // Mic button
        self.audioPubUnpubButton.frame = CGRectMake(self.bottomOverlayView.frame.size.width - 90,
                                                    0,
                                                    90,
                                                    PUBLISHER_BAR_HEIGHT);

        if ([[self.audioPubUnpubButton.layer sublayers] count] > 1) {
            borderLayer = [[self.audioPubUnpubButton.layer sublayers] objectAtIndex:1];
        } else {
            borderLayer = [[self.audioPubUnpubButton.layer sublayers] objectAtIndex:0];
        }

        borderLayer.frame = CGRectMake(-1,
                                       -1,
                                       CGRectGetWidth(_audioPubUnpubButton.frame) + 5,
                                       CGRectGetHeight(_audioPubUnpubButton.frame) + 2);

        self.leftArrowImgView.frame = CGRectMake(10,
                                                 videoContainerView.frame.size.height / 2 - 20,
                                                 40,
                                                 40);

        self.rightArrowImgView.frame = CGRectMake(videoContainerView.frame.size.width - 40 - 10,
                                                  videoContainerView.frame.size.height / 2 - 20,
                                                  40,
                                                  40);

        [videoContainerView setContentSize:CGSizeMake(videoContainerView.frame.size.width * (connectionsCount),
                                                      videoContainerView.frame.size.height)];
    } else if (orientation == UIInterfaceOrientationLandscapeLeft ||
               orientation == UIInterfaceOrientationLandscapeRight) {
        if (orientation == UIInterfaceOrientationLandscapeRight) {
            [videoContainerView setFrame:CGRectMake(0,
                                                    0,
                                                    self.view.frame.size.width,
                                                    self.view.frame.size.height)];

            [_publisher.view setFrame:CGRectMake(8,
                                                 self.view.frame.size.height - ((self.archiveOverlay.hidden ? 0 : ARCHIVE_BAR_HEIGHT) + 8 + PUBLISHER_PREVIEW_HEIGHT),
                                                 PUBLISHER_PREVIEW_WIDTH,
                                                 PUBLISHER_PREVIEW_HEIGHT)];

            UIView *containerView = self.archiveOverlay.superview;
            containerView.frame = CGRectMake(0,
                                             self.view.frame.size.height - ARCHIVE_BAR_HEIGHT,
                                             self.view.frame.size.width - PUBLISHER_BAR_HEIGHT,
                                             ARCHIVE_BAR_HEIGHT);

            // Archiving overlay
            self.archiveOverlay.frame = CGRectMake(0,
                                                   containerView.frame.size.height - ARCHIVE_BAR_HEIGHT,
                                                   containerView.frame.size.width,
                                                   ARCHIVE_BAR_HEIGHT);

            [self.bottomOverlayView removeFromSuperview];
            [self.view addSubview:self.bottomOverlayView];

            self.bottomOverlayView.frame = CGRectMake(self.view.frame.size.width - PUBLISHER_BAR_HEIGHT,
                                                      0,
                                                      PUBLISHER_BAR_HEIGHT,
                                                      self.view.frame.size.height);

            // Top overlay
            self.topOverlayView.frame = CGRectMake(0,
                                                   0,
                                                   self.view.frame.size.width - PUBLISHER_BAR_HEIGHT,
                                                   self.topOverlayView.frame.size.height);

            self.leftArrowImgView.frame = CGRectMake(10,
                                                     videoContainerView.frame.size.height / 2 - 20,
                                                     40,
                                                     40);

            self.rightArrowImgView.frame = CGRectMake(self.view.frame.size.width - 40 - 10 - PUBLISHER_BAR_HEIGHT,
                                                      videoContainerView.frame.size.height / 2 - 20,
                                                      40,
                                                      40);
        } else {
            [videoContainerView setFrame:CGRectMake(0,
                                                    0,
                                                    self.view.frame.size.width,
                                                    self.view.frame.size.height)];

            [_publisher.view setFrame:CGRectMake(8 + PUBLISHER_BAR_HEIGHT,
                                                 self.view.frame.size.height - ((self.archiveOverlay.hidden ? 0 : ARCHIVE_BAR_HEIGHT) + 8 + PUBLISHER_PREVIEW_HEIGHT),
                                                 PUBLISHER_PREVIEW_WIDTH,
                                                 PUBLISHER_PREVIEW_HEIGHT)];

            UIView *containerView = self.archiveOverlay.superview;
            containerView.frame = CGRectMake(PUBLISHER_BAR_HEIGHT,
                                             self.view.frame.size.height - ARCHIVE_BAR_HEIGHT,
                                             self.view.frame.size.width - PUBLISHER_BAR_HEIGHT,
                                             ARCHIVE_BAR_HEIGHT);

            [self.bottomOverlayView removeFromSuperview];
            [self.view addSubview:self.bottomOverlayView];

            self.bottomOverlayView.frame = CGRectMake(0,
                                                      0,
                                                      PUBLISHER_BAR_HEIGHT,
                                                      self.view.frame.size.height);

            // Archiving overlay
            self.archiveOverlay.frame = CGRectMake(0,
                                                   containerView.frame.size.height - ARCHIVE_BAR_HEIGHT,
                                                   containerView.frame.size.width,
                                                   ARCHIVE_BAR_HEIGHT);

            self.topOverlayView.frame = CGRectMake(PUBLISHER_BAR_HEIGHT,
                                                   0,
                                                   self.view.frame.size.width - PUBLISHER_BAR_HEIGHT,
                                                   self.topOverlayView.frame.size.height);

            self.leftArrowImgView.frame = CGRectMake(10 + PUBLISHER_BAR_HEIGHT,
                                                     videoContainerView.frame.size.height / 2 - 20,
                                                     40,
                                                     40);

            self.rightArrowImgView.frame = CGRectMake(self.view.frame.size.width - 40 - 10,
                                                      videoContainerView.frame.size.height / 2 - 20,
                                                      40,
                                                      40);
        }

        // Mic button
        CGRect frame = self.audioPubUnpubButton.frame;
        frame.origin.x = 0;
        frame.origin.y = 0;
        frame.size.width = PUBLISHER_BAR_HEIGHT;
        frame.size.height = 90;

        self.audioPubUnpubButton.frame = frame;

        // vertical border
        frame.origin.x = -1;
        frame.origin.y = -1;
        frame.size.width = 55;
        CALayer *borderLayer = [[self.audioPubUnpubButton.layer sublayers] objectAtIndex:1];
        borderLayer.frame = frame;

        // Camera button
        frame = self.cameraToggleButton.frame;
        frame.origin.x = 0;
        frame.origin.y = self.bottomOverlayView.frame.size.height - 100;
        frame.size.width = PUBLISHER_BAR_HEIGHT;
        frame.size.height = 90;

        self.cameraToggleButton.frame = frame;

        frame.origin.x = -1;
        frame.origin.y = 0;
        frame.size.height = 90;
        frame.size.width = 55;

        borderLayer = [[self.cameraToggleButton.layer sublayers] objectAtIndex:1];
        borderLayer.frame = CGRectMake(0,
                                       1,
                                       CGRectGetWidth(self.cameraToggleButton.frame),
                                       1);

        // call button
        frame = self.endCallButton.frame;
        frame.origin.x = 0;
        frame.origin.y = (self.bottomOverlayView.frame.size.height / 2) - (100 / 2);
        frame.size.width = PUBLISHER_BAR_HEIGHT;
        frame.size.height = 100;

        self.endCallButton.frame = frame;

        [videoContainerView setContentSize:CGSizeMake(videoContainerView.frame.size.width * connectionsCount,
                                                      videoContainerView.frame.size.height)];
    }

    if (isInFullScreen) {
        // call viewTapped to hide the views out of the screen.
        [[self topOverlayView].layer setValue:[NSNumber numberWithBool:NO]
                                       forKey:APP_IN_FULL_SCREEN];
        [self viewTapped:nil];
        [[self topOverlayView].layer setValue:[NSNumber numberWithBool:YES]
                                       forKey:APP_IN_FULL_SCREEN];

        self.topOverlayView.hidden = NO;
        self.bottomOverlayView.hidden = NO;
    }

    // re arrange subscribers
    [self reArrangeSubscribers];

    // set video container offset to current subscriber
    // FIXME: view tags are bad practice. if using them, document why
    [videoContainerView setContentOffset:CGPointMake(_currentSubscriber.view.tag * videoContainerView.frame.size.width, 0)
                                animated:YES];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    // current subscriber
    int currentPage = (int)(videoContainerView.contentOffset.x / videoContainerView.frame.size.width);

    if (currentPage < [allConnectionsIds count]) {
        // show current scrolled subscriber
        NSString *connectionId = [allConnectionsIds objectAtIndex:currentPage];
        [self showAsCurrentSubscriber:[allSubscribers objectForKey:connectionId]];
    }

    [self resetArrowsStates];
}

- (void)showAsCurrentSubscriber:(OTSubscriber *)subscriber {
    // scroll view tapping bug
    // FIXME: document what this bug is
    if (subscriber == _currentSubscriber) return;

    // unsubscribe currently running video
    _currentSubscriber.subscribeToVideo = NO;

    // update as current subscriber
    _currentSubscriber = subscriber;
    self.userNameLabel.text = _currentSubscriber.stream.name;

    // subscribe to new subscriber
    _currentSubscriber.subscribeToVideo = YES;

    self.audioSubUnsubButton.selected = !_currentSubscriber.subscribeToAudio;
}

- (void)setupSession {
    // setup one time session
    // FIXME: what does one time session mean?
    if (_session) {
        _session = nil;
    }

    _session = [[OTSession alloc] initWithApiKey:kApiKey
                                       sessionId:kSessionId
                                        delegate:self];
    [_session connectWithToken:kToken error:nil];
    [self setupPublisher];
}

- (void)setupPublisher {
    // create one time publisher and style publisher
    _publisher = [[OTPublisher alloc] initWithDelegate:self];
    _publisher.publishVideo = false;

    // set name of the publisher
    //[_publisher setName:self.publisherName];

    [self willAnimateRotationToInterfaceOrientation:[[UIApplication sharedApplication] statusBarOrientation]
                                           duration:1.0];

    [self.view addSubview:_publisher.view];

    // add pan gesture to publisher
    UIPanGestureRecognizer *pgr = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handlePan:)];
    [_publisher.view addGestureRecognizer:pgr];
    pgr.delegate = self;
    _publisher.view.userInteractionEnabled = YES;
}

- (IBAction)handlePan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:_publisher.view];
    CGRect recognizerFrame = recognizer.view.frame;

    recognizerFrame.origin.x += translation.x;
    recognizerFrame.origin.y += translation.y;

    if (CGRectContainsRect(self.view.bounds, recognizerFrame)) {
        recognizer.view.frame = recognizerFrame;
    } else {
        if (recognizerFrame.origin.y < self.view.bounds.origin.y) {
            recognizerFrame.origin.y = 0;
        } else if (recognizerFrame.origin.y + recognizerFrame.size.height > self.view.bounds.size.height) {
            recognizerFrame.origin.y = self.view.bounds.size.height - recognizerFrame.size.height;
        }

        if (recognizerFrame.origin.x < self.view.bounds.origin.x) {
            recognizerFrame.origin.x = 0;
        } else if (recognizerFrame.origin.x + recognizerFrame.size.width > self.view.bounds.size.width) {
            recognizerFrame.origin.x = self.view.bounds.size.width - recognizerFrame.size.width;
        }
    }

    [recognizer setTranslation:CGPointMake(0, 0) inView:_publisher.view];
}

- (void)handleArrowTap:(UIPanGestureRecognizer *)recognizer {
    CGPoint touchPoint = [recognizer locationInView:self.leftArrowImgView];

    // FIXME: everything is the same except the `currentPage +/- 1` expression
    if ([self.leftArrowImgView pointInside:touchPoint withEvent:nil]) {
        int currentPage = (int)(videoContainerView.contentOffset.x / videoContainerView.frame.size.width);

        OTSubscriber *nextSubscriber = [allSubscribers objectForKey:[allConnectionsIds objectAtIndex:currentPage - 1]];

        [self showAsCurrentSubscriber:nextSubscriber];

        [videoContainerView setContentOffset:CGPointMake(_currentSubscriber.view.frame.origin.x, 0) animated:YES];
    } else {
        int currentPage = (int)(videoContainerView.contentOffset.x / videoContainerView.frame.size.width);

        OTSubscriber *nextSubscriber = [allSubscribers objectForKey:[allConnectionsIds objectAtIndex:currentPage + 1]];

        [self showAsCurrentSubscriber:nextSubscriber];

        [videoContainerView setContentOffset:CGPointMake(_currentSubscriber.view.frame.origin.x, 0) animated:YES];
    }

    [self resetArrowsStates];
}

- (void)resetArrowsStates {
    self.leftArrowImgView.hidden = YES;
    self.rightArrowImgView.hidden = YES;

    // FIXME: again?
    BOOL isInFullScreen = [[[self topOverlayView].layer valueForKey:APP_IN_FULL_SCREEN] boolValue];

    if (isInFullScreen || !_currentSubscriber ||
        (_currentSubscriber.view.tag == 0 && [allConnectionsIds count] <= 1)) {
        return;
    }

    if (_currentSubscriber.view.tag == 0 && [allConnectionsIds count] > 1) {
        self.rightArrowImgView.hidden = NO;
    } else if (_currentSubscriber.view.tag == [allConnectionsIds count] - 1 &&
               [allConnectionsIds count] > 1) {
        self.leftArrowImgView.hidden = NO;
    } else {
        self.leftArrowImgView.hidden = NO;
        self.rightArrowImgView.hidden = NO;
    }
}

#pragma mark - OpenTok Session

- (void)sessionDidConnect:(OTSession *)session {
    //Forces the application to not let the iPhone go to sleep.
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    // now publish
    OTError *error;
    [_session publish:_publisher error:&error];

    if (error) {
        [self showAlert:[error localizedDescription]];
    }

    [self.spinningWheel stopAnimating];
}

- (void)reArrangeSubscribers {
    CGFloat containerWidth = CGRectGetWidth(videoContainerView.bounds);
    CGFloat containerHeight = CGRectGetHeight(videoContainerView.bounds);
    NSUInteger count = [allConnectionsIds count];

    // arrange all subscribers horizontally one by one.
    // FIXME: iterate using for-in
    for (int i = 0; i < [allConnectionsIds count]; i++) {
        OTSubscriber *subscriber = [allSubscribers valueForKey:[allConnectionsIds objectAtIndex:i]];
        subscriber.view.tag = i;
        [subscriber.view setFrame:CGRectMake(i * CGRectGetWidth(videoContainerView.bounds),
                                             0,
                                             containerWidth,
                                             containerHeight)];
        [videoContainerView addSubview:subscriber.view];
    }

    [videoContainerView setContentSize:CGSizeMake(videoContainerView.frame.size.width * count,
                                                  videoContainerView.frame.size.height - 18)];
    [videoContainerView setContentOffset:CGPointMake(_currentSubscriber.view.frame.origin.x, 0)
                                animated:YES];
}

- (void)sessionDidDisconnect:(OTSession *)session {
    // remove all subscriber views from video container
    // FIXME: iterate using for-in, or actually just use a block API
    for (int i = 0; i < [allConnectionsIds count]; i++) {
        OTSubscriber *subscriber = [allSubscribers valueForKey:[allConnectionsIds objectAtIndex:i]];
        [subscriber.view removeFromSuperview];
    }

    [_publisher.view removeFromSuperview];

    [allSubscribers removeAllObjects];
    [allConnectionsIds removeAllObjects];
    [allStreams removeAllObjects];

    _currentSubscriber = nil;
    _publisher = nil;

    if (self.archiveStatusImgView.isAnimating) {
        [self stopArchiveAnimation];
    }

    if ([self.navigationController.viewControllers indexOfObject:self] != NSNotFound) {
        [self.navigationController popViewControllerAnimated:YES];
    }

    //Allows the iPhone to go to sleep if there is not touch activity.
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)session:(OTSession *)session streamDestroyed:(OTStream *)stream {
    // unsubscribe first
    OTSubscriber *subscriber = [allSubscribers objectForKey:stream.connection.connectionId];

    // FIXME: never unsubscribes?
    //    OTError *error = nil;
    //	[_session unsubscribe:subscriber error:&error];
    //    if (error)
    //    {
    //        [self showAlert:[error localizedDescription]];
    //    }

    // remove from superview
    [subscriber.view removeFromSuperview];

    [allSubscribers removeObjectForKey:stream.connection.connectionId];
    [allConnectionsIds removeObject:stream.connection.connectionId];

    _currentSubscriber = nil;
    [self reArrangeSubscribers];

    // show first subscriber
    if ([allConnectionsIds count] > 0) {
        NSString *firstConnection = [allConnectionsIds objectAtIndex:0];
        [self showAsCurrentSubscriber:[allSubscribers objectForKey:firstConnection]];
    }

    [self resetArrowsStates];
}

- (void)createSubscriber:(OTStream *)stream {
    if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground ||
        [[UIApplication sharedApplication] applicationState] == UIApplicationStateInactive) {
        [backgroundConnectedStreams addObject:stream];
    } else {
        // create subscriber
        OTSubscriber *subscriber = [[OTSubscriber alloc] initWithStream:stream delegate:self];

        // subscribe now
        OTError *error = nil;
        [_session subscribe:subscriber error:&error];

        if (error) {
            [self showAlert:[error localizedDescription]];
        }
    }
}

- (void)subscriberDidConnectToStream:(OTSubscriberKit *)subscriber {
    // create subscriber
    OTSubscriber *sub = (OTSubscriber *)subscriber;

    [allSubscribers setObject:subscriber forKey:sub.stream.connection.connectionId];
    [allConnectionsIds addObject:sub.stream.connection.connectionId];

    // set subscriber position and size
    CGFloat containerWidth = CGRectGetWidth(videoContainerView.bounds);
    CGFloat containerHeight = CGRectGetHeight(videoContainerView.bounds);
    NSUInteger count = [allConnectionsIds count] - 1;
    [sub.view setFrame:CGRectMake(count * CGRectGetWidth(videoContainerView.bounds),
                                  0,
                                  containerWidth,
                                  containerHeight)];
    // FIXME: view tags are back practice, document why they are being used
    sub.view.tag = count;

    // add to video container view
    [videoContainerView insertSubview:sub.view
                         belowSubview:_publisher.view];

    // default subscribe video to the first subscriber only
    if (!_currentSubscriber) {
        [self showAsCurrentSubscriber:(OTSubscriber *)subscriber];
    } else {
        subscriber.subscribeToVideo = NO;
    }

    // set scrollview content width based on number of subscribers connected.
    [videoContainerView setContentSize:CGSizeMake(videoContainerView.frame.size.width * (count + 1),
                                                  videoContainerView.frame.size.height - 18)];

    [allStreams setObject:sub.stream forKey:sub.stream.connection.connectionId];

    [self resetArrowsStates];
}

- (void)session:(OTSession *)mySession streamCreated:(OTStream *)stream {
    // create remote subscriber
    [self createSubscriber:stream];
}

- (void)session:(OTSession *)session didFailWithError:(OTError *)error {
    [self showAlert:[NSString stringWithFormat:@"There was an error connecting to session %@", error.localizedDescription]];
    [self endCallAction:nil];
}

- (void)publisher:(OTPublisher *)publisher didFailWithError:(OTError *)error {
    [self showAlert:[NSString stringWithFormat:@"There was an error publishing."]];
    [self endCallAction:nil];
}

- (void)subscriber:(OTSubscriber *)subscriber didFailWithError:(OTError *)error {
    // FIXME: do something more helpful here
    NSLog(@"subscriber could not connect to stream");
}

#pragma mark - Helper Methods

- (IBAction)endCallAction:(UIButton *)button {
    if (_session && _session.sessionConnectionStatus == OTSessionConnectionStatusConnected) {
        // disconnect session
        [_session disconnect:nil];
        return;
    } else {
        //all other cases just go back to home screen.
        if ([self.navigationController.viewControllers indexOfObject:self] != NSNotFound) {
            [self.navigationController popViewControllerAnimated:YES];
        }
    }
}

- (void)showAlert:(NSString *)string {
    // show alertview on main UI
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Message from video session"
                                                        message:string
                                                       delegate:self
                                              cancelButtonTitle:@"OK"  // FIXME: cancel is ok?
                                              otherButtonTitles:nil];
        [alert show];
    });
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Other Interactions

- (IBAction)toggleAudioSubscribe:(id)sender {
    if (_currentSubscriber.subscribeToAudio == YES) {
        _currentSubscriber.subscribeToAudio = NO;
        self.audioSubUnsubButton.selected = YES;
    } else {
        _currentSubscriber.subscribeToAudio = YES;
        self.audioSubUnsubButton.selected = NO;
    }
}

// FIXME: remove observer somewhere else (used to be in dealloc)
//[[NSNotificationCenter defaultCenter]
// removeObserver:self
// name:UIApplicationWillResignActiveNotification
// object:nil];
//
//[[NSNotificationCenter defaultCenter]
// removeObserver:self
// name:UIApplicationDidBecomeActiveNotification
// object:nil];

- (IBAction)toggleCameraPosition:(id)sender {
    if (_publisher.cameraPosition == AVCaptureDevicePositionBack) {
        _publisher.cameraPosition = AVCaptureDevicePositionFront;
        self.cameraToggleButton.selected = NO;
        self.cameraToggleButton.highlighted = NO;
    } else if (_publisher.cameraPosition == AVCaptureDevicePositionFront) {
        _publisher.cameraPosition = AVCaptureDevicePositionBack;
        self.cameraToggleButton.selected = YES;
        self.cameraToggleButton.highlighted = YES;
    }
}

- (IBAction)toggleAudioPublish:(id)sender {
    if (_publisher.publishAudio == YES) {
        _publisher.publishAudio = NO;
        self.audioPubUnpubButton.selected = YES;
    } else {
        _publisher.publishAudio = YES;
        self.audioPubUnpubButton.selected = NO;
    }
}

- (void)startArchiveAnimation {
    if (self.archiveOverlay.hidden) {
        self.archiveOverlay.hidden = NO;
        CGRect frame = _publisher.view.frame;
        frame.origin.y -= ARCHIVE_BAR_HEIGHT;
        _publisher.view.frame = frame;
    }

    // FIXME: again?
    BOOL isInFullScreen = [[[self topOverlayView].layer valueForKey:APP_IN_FULL_SCREEN] boolValue];

    // show UI if it is in full screen
    if (isInFullScreen) {
        [self viewTapped:[self.view.gestureRecognizers objectAtIndex:0]];
    }

    // set animation images
    self.archiveStatusLbl.text = @"Archiving call";
    UIImage *imageOne = [UIImage imageNamed:@"archiving_on-10.png"];
    UIImage *imageTwo = [UIImage imageNamed:@"archiving_pulse-Small.png"];
    NSArray *imagesArray = [NSArray arrayWithObjects:imageOne, imageTwo, nil];
    self.archiveStatusImgView.animationImages = imagesArray;
    self.archiveStatusImgView.animationDuration = 1.0f;
    self.archiveStatusImgView.animationRepeatCount = 0;
    [self.archiveStatusImgView startAnimating];
}

- (void)stopArchiveAnimation {
    [self.archiveStatusImgView stopAnimating];
    self.archiveStatusLbl.text = @"Archiving off";
    self.archiveStatusImgView.image = [UIImage imageNamed:@"archiving-off-15.png"];
}

- (void)session:(OTSession *)session archiveStartedWithId:(NSString *)archiveId name:(NSString *)name {
    [self startArchiveAnimation];
}

- (void)session:(OTSession *)session archiveStoppedWithId:(NSString *)archiveId {
    [self stopArchiveAnimation];
}

- (void)      session:(OTSession *)session
    connectionCreated:(OTConnection *)connection {
    _otherConnection = connection;
}

#pragma mark - hahahhaha
- (void)       session:(OTSession *)session
    receivedSignalType:(NSString *)type
        fromConnection:(OTConnection *)connection
            withString:(NSString *)string {
    NSLog(@"%@", string);

    UIView *spot = [UIView new];
    spot.backgroundColor = [UIColor redColor];

    spot.frame = CGRectMake(0, 0, 20, 20);
    spot.layer.cornerRadius = 10;
    spot.center = CGPointFromString(string);
    [self.view addSubview:spot];

    [UIView animateWithDuration:0.5 animations:^{
        spot.alpha = 0.1;
    } completion:^(BOOL finished) {
        [spot removeFromSuperview];
    }];

//    [self.view hitTest:CGPointZero withEvent:nil];
}

- (void)sendTapData:(CGPoint)location {
    NSString *string = NSStringFromCGPoint(location);

    [_session signalWithType:@"Touch" string:string connection:_otherConnection error:nil];
}

@end
