#import "CameraRenderController.h"
#import <CoreVideo/CVOpenGLESTextureCache.h>
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/glext.h>

@implementation CameraRenderController
@synthesize context = _context;
@synthesize delegate;


- (CameraRenderController *)init {
  if (self = [super init]) {
    self.renderLock = [[NSLock alloc] init];
  }
  return self;
}

- (void)loadView {
  GLKView *glkView = [[GLKView alloc] init];
  [glkView setBackgroundColor:[UIColor blackColor]];
  [self setView:glkView];
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];

  if (!self.context) {
    NSLog(@"Failed to create ES context");
  }

  CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.context, NULL, &_videoTextureCache);
  if (err) {
    NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
    return;
  }

  GLKView *view = (GLKView *)self.view;
  view.context = self.context;
  view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
  view.contentMode = UIViewContentModeScaleToFill;

  glGenRenderbuffers(1, &_renderBuffer);
  glBindRenderbuffer(GL_RENDERBUFFER, _renderBuffer);

  self.ciContext = [CIContext contextWithEAGLContext:self.context];
  self.opts = @{ CIDetectorAccuracy : CIDetectorAccuracyHigh, CIDetectorSmile : @(YES), CIDetectorEyeBlink: @(YES) };
  self.detector = [CIDetector detectorOfType:CIDetectorTypeFace
                                            context:self.ciContext
                                            options:self.opts];
  self.leftEyeClosed = false;
  self.rightEyeClosed = false;

  if (self.dragEnabled) {
    //add drag action listener
    NSLog(@"Enabling view dragging");
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.view addGestureRecognizer:drag];
  }

  if (self.tapToTakePicture) {
    //tap to take picture
    UITapGestureRecognizer *takePictureTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTakePictureTap:)];
    [self.view addGestureRecognizer:takePictureTap];
  }

  self.view.userInteractionEnabled = self.dragEnabled || self.tapToTakePicture;
}

- (void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(appplicationIsActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationEnteredForeground:)
                                               name:UIApplicationWillEnterForegroundNotification
                                             object:nil];

  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Starting session");
      [self.sessionManager.session startRunning];
      });
}

- (void) viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIApplicationDidBecomeActiveNotification
                                                object:nil];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIApplicationWillEnterForegroundNotification
                                                object:nil];

  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Stopping session");
      [self.sessionManager.session stopRunning];
      });
}

- (void) handleTakePictureTap:(UITapGestureRecognizer*)recognizer {
  NSLog(@"handleTakePictureTap");
  [self.delegate invokeTakePicture];
}

- (IBAction)handlePan:(UIPanGestureRecognizer *)recognizer {
        CGPoint translation = [recognizer translationInView:self.view];
        recognizer.view.center = CGPointMake(recognizer.view.center.x + translation.x,
            recognizer.view.center.y + translation.y);
        [recognizer setTranslation:CGPointMake(0, 0) inView:self.view];
}

- (void) appplicationIsActive:(NSNotification *)notification {
  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Starting session");
      [self.sessionManager.session startRunning];
      });
}

- (void) applicationEnteredForeground:(NSNotification *)notification {
  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Stopping session");
      [self.sessionManager.session stopRunning];
      });
}

- (UIImage *)imageWithString:(NSString *)text size:(CGSize) size
{
    UIGraphicsBeginImageContextWithOptions(size, NO, 1.0);
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowOffset = CGSizeMake(0.f, -0.5f);
    shadow.shadowColor = [UIColor darkGrayColor];
    shadow.shadowBlurRadius = 0.f;
    UIFont *font = [UIFont boldSystemFontOfSize:48.0f];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    //style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByClipping;
    NSDictionary *attributes = @{
           NSFontAttributeName: font,
           NSParagraphStyleAttributeName: style,
           NSShadowAttributeName: shadow,
           NSForegroundColorAttributeName: [UIColor whiteColor],
           NSBackgroundColorAttributeName: [UIColor clearColor]
    };
    [text drawInRect:CGRectMake(0, 0, size.width, size.height)
      withAttributes:attributes];

    UIImage *image = nil;
    image = UIGraphicsGetImageFromCurrentImageContext();
    UIImage *blank = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

-(void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  if ([self.renderLock tryLock]) {
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];

    ////-->
    //CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    //size_t width = CVPixelBufferGetWidth(pixelBuffer);
    //size_t height = CVPixelBufferGetHeight(pixelBuffer);
    //size_t lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    //size_t *lumaBaseAddress = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    //bool overExposure = false;

    ////for(uint8_t y = 0; y < height; y+=100) {
    ////  for(uint8_t x = 0; x < width; x+=100) {
    ////    uint16_t lumaIndex = x+y*lumaBytesPerRow;
    ////    uint8_t yp = lumaBaseAddress[lumaIndex];
    ////    NSLog(@"x:%d y:%d yp:%d", x, y, yp);
    ////    if (yp > 250) {
    ////      overExposure = true;
    ////    }
    ////  }
    ////}
    //if (overExposure) {
    //  //NSLog(@"akarui!");
    //}
    ////NSLog(@"w:%d h:%d", width, height);

    //CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    ////<--

    CGFloat scaleHeight = self.view.frame.size.height/image.extent.size.height;
    CGFloat scaleWidth = self.view.frame.size.width/image.extent.size.width;

    CGFloat scale, x, y, scaleq, xq, yq;
    if (scaleHeight < scaleWidth) {
      scale = scaleWidth;
      x = 0;
      y = ((scale * image.extent.size.height) - self.view.frame.size.height ) / 2;
    } else {
      scale = scaleHeight;
      x = ((scale * image.extent.size.width) - self.view.frame.size.width )/ 2;
      y = 0;
    }
    scaleq = scale / 1;
    xq = x / 1;
    yq = y / 1;

    // scale - translate
    CGAffineTransform xscale = CGAffineTransformMakeScale(scale, scale);
    CGAffineTransform xlate = CGAffineTransformMakeTranslation(-x, -y);
    CGAffineTransform xform =  CGAffineTransformConcat(xscale, xlate);

    CIFilter *centerFilter = [CIFilter filterWithName:@"CIAffineTransform"  keysAndValues:
      kCIInputImageKey, image,
      kCIInputTransformKey, [NSValue valueWithBytes:&xform objCType:@encode(CGAffineTransform)],
      nil];

    CIImage *transformedImage = [centerFilter outputImage];

    // crop
    CIFilter *cropFilter = [CIFilter filterWithName:@"CICrop"];
    CIVector *cropRect = [CIVector vectorWithX:0 Y:0 Z:self.view.frame.size.width W:self.view.frame.size.height];
    [cropFilter setValue:transformedImage forKey:kCIInputImageKey];
    [cropFilter setValue:cropRect forKey:@"inputRectangle"];
    CIImage *croppedImage = [cropFilter outputImage];

    //fix front mirroring
    if (self.sessionManager.defaultCamera == AVCaptureDevicePositionFront) {
      CGAffineTransform matrix = CGAffineTransformTranslate(CGAffineTransformMakeScale(-1, 1), 0, croppedImage.extent.size.height);
      croppedImage = [croppedImage imageByApplyingTransform:matrix];
    }

    NSArray *features = [self.detector featuresInImage:croppedImage options:self.opts];
    bool isFaceExists = false;
    bool isSmiled = false;
    for (CIFaceFeature *f in features) {
      if (f.hasLeftEyePosition &&
          f.hasRightEyePosition &&
          f. hasMouthPosition)
      {
        isFaceExists = true;
      }
      if (f.hasSmile) {
        isSmiled = true;
      }
      if (f.leftEyeClosed) {
        self.leftEyeClosed = true;
      }
      if (f.rightEyeClosed) {
        self.rightEyeClosed = true;
      }
      //if (f.hasLeftEyePosition) {
      //  NSLog(@"Left eye %g %g", f.leftEyePosition.x, f.leftEyePosition.y);
      //}
      //if (f.hasRightEyePosition) {
      //  NSLog(@"Right eye %g %g", f.rightEyePosition.x, f.rightEyePosition.y);
      //}
      //if (f.hasMouthPosition) {
      //  NSLog(@"Mouth %g %g", f.mouthPosition.x, f.mouthPosition.y);
      //}
    }
    if (!isFaceExists) {
      self.leftEyeClosed = false;
      self.rightEyeClosed = false;
    }
    CGImageRef finalImage = [self.ciContext createCGImage:croppedImage fromRect:croppedImage.extent];
    // データプロバイダを取得する
    CGDataProviderRef dataProvider = CGImageGetDataProvider(finalImage);
    // ビットマップデータを取得する
    CFDataRef dataRef = CGDataProviderCopyData(dataProvider);
    UInt8* buffer = (UInt8*)CFDataGetBytePtr(dataRef);
    size_t bytesPerRow = CGImageGetBytesPerRow(finalImage);
    size_t imageWidth = CGImageGetWidth(finalImage);
    size_t imageHeight = CGImageGetHeight(finalImage);
    //NSLog(@"bpr:%d w:%d h:%d", bytesPerRow, imageWidth, imageHeight);
    int outerScanRad = imageWidth / 3;
    int innerScanRad = imageWidth / 8;
    int outerCircle = 2 * M_PI * outerScanRad;
    int innerCircle = 2 * M_PI * innerScanRad;
    int cx = imageWidth / 2;
    int cy = imageHeight / 2;
    int outerBrightCount = 0;
    int innerBrightCount = 0;
    int outerDarkCount = 0;
    int innerDarkCount = 0;
    double radStep = 2 * M_PI / outerCircle;
    for (int t = 0; t < outerCircle; t++) {
      int x = cx + outerScanRad * cos(t * radStep);
      int y = cy + outerScanRad * sin(t * radStep);
      UInt8* pixelPtr = buffer + (int)(y) * bytesPerRow + (int)(x) * 4;
      UInt8 r = *(pixelPtr + 2);
      UInt8 g = *(pixelPtr + 1);
      UInt8 b = *(pixelPtr + 0);
      //NSLog(@"t:%d x:%d y:%d R:%d G:%d B:%d", t, x, y, r, g, b);
      if (r > 252 && g > 241 && b > 226) {
        outerBrightCount++;
      }
      if (r < 128 && g < 128 && b < 128) {
        outerDarkCount++;
      }
    }
    for (int t = 0; t < innerCircle; t++) {
      int x = cx + innerScanRad * cos(t * radStep);
      int y = cy + innerScanRad * sin(t * radStep);
      UInt8* pixelPtr = buffer + (int)(y) * bytesPerRow + (int)(x) * 4;
      UInt8 r = *(pixelPtr + 2);
      UInt8 g = *(pixelPtr + 1);
      UInt8 b = *(pixelPtr + 0);
      //NSLog(@"t:%d x:%d y:%d R:%d G:%d B:%d", t, x, y, r, g, b);
      if (r > 252 && g > 241 && b > 226) {
        innerBrightCount++;
      }
      if (r < 128 && g < 128 && b < 128) {
        innerDarkCount++;
      }
    }
    CFRelease(dataRef);
    CGImageRelease(finalImage); // release CGImageRef to remove memory leaks

    double outerBrightRate = (double)outerBrightCount/ outerCircle;
    double innerBrightRate = (double)innerBrightCount/ innerCircle;
    double outerDarkRate = (double)outerDarkCount/ outerCircle;
    double innerDarkRate = (double)innerDarkCount/ innerCircle;
    NSString *info = [NSString stringWithFormat: @"Bright(%.1lf, %.1lf) Dark(%.1lf, %.1lf)", outerBrightRate, innerBrightRate, outerDarkRate, innerDarkRate];
    NSString *remark = @"";
    NSString *blink = @"";
    NSString *text = @"";
    if (innerDarkRate > 0.5) {
      remark = @"🌑";
    }
    //else if (outerBrightRate > 0.01) {
    //  remark = @"🌅";
    //}
    else {
      if (isFaceExists) {
        if (isSmiled) {
          remark = @"😊";
        } else {
          remark = @"😒";
        }
      } else {
        remark = @"👻";
      }
    }
    if (self.leftEyeClosed && self.rightEyeClosed) {
      blink = @"😉";
    }
    //text = [NSString stringWithFormat: @"%1$@", info];
    text = [NSString stringWithFormat: @"%1$@ %2$@", remark, blink];

    UIImage *textImage = [self imageWithString:text size:CGSizeMake(imageWidth, imageHeight)];
    CIImage *maskImage = [CIImage imageWithCGImage:textImage.CGImage];

    // 合成
    CIFilter *compositFilter = [CIFilter filterWithName:@"CISourceOverCompositing"];
    [compositFilter setValue:[maskImage imageByApplyingTransform:CGAffineTransformMakeTranslation(-(CGFloat)imageWidth, (CGFloat)imageHeight)]
                      forKey:kCIInputImageKey];
    [compositFilter setValue:croppedImage forKey:kCIInputBackgroundImageKey];
    CIImage *resultImage = [compositFilter outputImage];

    self.latestFrame = resultImage;

    CGFloat pointScale;
    if ([[UIScreen mainScreen] respondsToSelector:@selector(nativeScale)]) {
      pointScale = [[UIScreen mainScreen] nativeScale];
    } else {
      pointScale = [[UIScreen mainScreen] scale];
    }
    CGRect dest = CGRectMake(0, 0, self.view.frame.size.width*pointScale, self.view.frame.size.height*pointScale);

    [self.ciContext drawImage:resultImage inRect:dest fromRect:[resultImage extent]];
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
    [(GLKView *)(self.view)display];
    [self.renderLock unlock];
  }
}

- (void)viewDidUnload {
  [super viewDidUnload];

  if ([EAGLContext currentContext] == self.context) {
    [EAGLContext setCurrentContext:nil];
  }
  self.context = nil;
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
  // Release any cached data, images, etc. that aren't in use.
}

- (BOOL)shouldAutorotate {
  return YES;
}

-(void) willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
  [self.sessionManager updateOrientation:[self.sessionManager getCurrentOrientation:toInterfaceOrientation]];
}

@end
