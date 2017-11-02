#import "CameraRenderController.h"
#import <CoreVideo/CVOpenGLESTextureCache.h>
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/glext.h>

static const int IMAGE_OK = 0;
static const int IMAGE_TOO_DARK = 1;
static const int IMAGE_TOO_BRIGHT = 2;
static const int EYE_NOT_DETECTED = 0;
static const int EYE_DETECTED = 1;
static const int EYE_BLINK_DETECTED = 2;

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
  self.brightnessStat = IMAGE_TOO_DARK;
  self.eyeStat = EYE_NOT_DETECTED;

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

- (UIImage *)imageWithString:(NSString *)text size:(CGSize) size {
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

-(UInt8)rgb2Luma:(UInt8)r g:(UInt8) g b:(UInt8) b {
  return (UInt8)(0.257 * r + 0.504 * g + 0.098 * b) + 16;
}

-(int)checkSingleEyeImage:(UInt8*)buffer bpr:(size_t)bpr size:(CGSize)size scanArea:(CGRect)scanArea {
  int ox = size.width + scanArea.origin.x;
  int oy = size.height - (scanArea.origin.y - size.height);
  UInt8 maxLuma = 0;
  UInt8 minLuma = 255;
  //NSLog(@"(%d,%d), (%d,%d), %d x %d", (int)size.width, (int)size.height, ox, (int)oy, (int)scanArea.size.width, (int)scanArea.size.height);
  for (int y = oy; y < oy + scanArea.size.height; y++) {
    if (y < 0 || y >= size.height) {
      continue;
    }
    for (int x = ox; x < ox + scanArea.size.width; x++) {
      if (x < 0 || x >= size.width) {
        continue;
      }
      UInt8* pixelPtr = buffer + (int)(y) * bpr + (int)(x) * 4;
      UInt8 r = *(pixelPtr + 2);
      UInt8 g = *(pixelPtr + 1);
      UInt8 b = *(pixelPtr + 0);
      UInt8 luma = [self rgb2Luma:r g:g b:b];
      if (luma < minLuma) {
        minLuma = luma;
      }
      if (luma > maxLuma) {
        maxLuma = luma;
      }
    }
  }
  //NSLog(@"%3d ~ %3d", minLuma, maxLuma);
  if (maxLuma < 100) {
    return IMAGE_TOO_DARK;
  } else if (minLuma > 80) {
    return IMAGE_TOO_BRIGHT;
  } else {
    return IMAGE_OK;
  }
}

-(int)checkEyesImage:(UInt8*)buffer bpr:(size_t)bpr size:(CGSize)size left:(CGPoint)left right:(CGPoint)right {
  int scanWidth = (right.x - left.x)/2;
  int scanHight = scanWidth / 2;
  //NSLog(@"eye %d x %d", scanWidth, scanHight);
  int statLeft = [self checkSingleEyeImage:buffer bpr:bpr size:size scanArea:CGRectMake(left.x - scanWidth/2, left.y - scanHight/2, scanWidth, scanHight)];
  int statRight = [self checkSingleEyeImage:buffer bpr:bpr size:size scanArea:CGRectMake(right.x - scanWidth/2, right.y - scanHight/2, scanWidth, scanHight)];
  if (statLeft == statRight) {
    return statLeft;
  } else {
    return IMAGE_OK;
  }
}

-(CIImage*)checkFace:(CIImage*)image {
    NSArray *features = [self.detector featuresInImage:image options:self.opts];
    bool isFaceExists = false;
    bool isSmiled = false;
    bool isMultiFace = false;
    int brightnessStat = self.brightnessStat;
    int eyeStat = EYE_NOT_DETECTED;

    CGImageRef finalImage = [self.ciContext createCGImage:image fromRect:image.extent];
    // データプロバイダを取得する
    CGDataProviderRef dataProvider = CGImageGetDataProvider(finalImage);
    // ビットマップデータを取得する
    CFDataRef dataRef = CGDataProviderCopyData(dataProvider);
    UInt8* buffer = (UInt8*)CFDataGetBytePtr(dataRef);
    size_t bytesPerRow = CGImageGetBytesPerRow(finalImage);
    size_t imageWidth = CGImageGetWidth(finalImage);
    size_t imageHeight = CGImageGetHeight(finalImage);
    if ([features count] > 1) {
      isMultiFace = true;
    } else {
      for (CIFaceFeature *f in features) {
        if (f.hasLeftEyePosition &&
            f.hasRightEyePosition &&
            f. hasMouthPosition)
        {
          isFaceExists = true;
          if (f.hasSmile) {
            isSmiled = true;
          }
          if (!f.leftEyeClosed && !f.rightEyeClosed) {
            brightnessStat = [self checkEyesImage:buffer bpr:bytesPerRow size:CGSizeMake(imageWidth, imageHeight) left:f.leftEyePosition right:f.rightEyePosition];
          }
          else {
            if (f.leftEyeClosed) {
              self.leftEyeClosed = true;
            }
            if (f.rightEyeClosed) {
              self.rightEyeClosed = true;
            }
          }
        }
      }
    }
    if (!isFaceExists) {
      self.leftEyeClosed = false;
      self.rightEyeClosed = false;
    } else {
      eyeStat = EYE_DETECTED;
      if (self.leftEyeClosed && self.rightEyeClosed) {
        eyeStat = EYE_BLINK_DETECTED;
      }
    }
    CFRelease(dataRef);
    CGImageRelease(finalImage); // release CGImageRef to remove memory leaks
    if (self.brightnessStat != brightnessStat) {
      self.brightnessStat = brightnessStat;
      [self.delegate invokeBrightnessNotification:self.brightnessStat];
    }
    if (self.eyeStat != eyeStat) {
      self.eyeStat = eyeStat;
      [self.delegate invokeEyesNotification:self.eyeStat];
    }

    NSString *brightness = @"";
    NSString *detect = @"";
    NSString *blink = @"";
    NSString *text = @"";
    if (isFaceExists) {
      if (isSmiled) {
        detect = @"😄";
      } else {
        detect = @"😊";
      }
      if (self.brightnessStat == IMAGE_TOO_DARK) {
        brightness = @"🌑";
      } else if (self.brightnessStat == IMAGE_TOO_BRIGHT) {
        brightness = @"🌅";
      } else {
        brightness = @"";
      }
    } else if (isMultiFace) {
      detect = @"👥";
      brightness = @"";
    } else {
      detect = @"👻";
      brightness = @"";
    }
    if (self.eyeStat == EYE_BLINK_DETECTED) {
      blink = @"😉";
    }

    NSString* latestMessage = [NSString stringWithFormat: @"%1$@ %2$@ %3$@", detect, blink, brightness];

    UIImage *textImage = [self imageWithString:latestMessage size:CGSizeMake(imageWidth, imageHeight)];
    CIImage *maskImage = [CIImage imageWithCGImage:textImage.CGImage];

    // 合成
    CIFilter *compositFilter = [CIFilter filterWithName:@"CISourceOverCompositing"];
    [compositFilter setValue:[maskImage imageByApplyingTransform:CGAffineTransformMakeTranslation(-(CGFloat)imageWidth, (CGFloat)imageHeight)]
                      forKey:kCIInputImageKey];
    [compositFilter setValue:image forKey:kCIInputBackgroundImageKey];
    return [compositFilter outputImage];
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

    CGFloat scale, x, y;
    if (scaleHeight < scaleWidth) {
      scale = scaleWidth;
      x = 0;
      y = ((scale * image.extent.size.height) - self.view.frame.size.height ) / 2;
    } else {
      scale = scaleHeight;
      x = ((scale * image.extent.size.width) - self.view.frame.size.width )/ 2;
      y = 0;
    }

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

    CIImage *resultImage = [self checkFace:croppedImage];

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
