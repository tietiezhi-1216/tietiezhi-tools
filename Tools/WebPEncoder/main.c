// Native PNG-to-animated-WebP helper. libwebp is statically linked by the build script.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <webp/encode.h>
#include <webp/mux.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int number(const char *text, int min, int max) {
  char *end = NULL;
  errno = 0;
  long n = strtol(text, &end, 10);
  if (errno || !end || *end || n < min || n > max) return -1;
  return (int)n;
}
static CGImageRef load(const char *path) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
  if (!url) return NULL;
  CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
  CFRelease(url);
  if (!source) return NULL;
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  return image;
}
int main(int argc, const char **argv) {
  int delay = 100, loop = 0, quality = 80, lossless = 1;
  const char *destination = NULL;
  const char **frames = calloc((size_t)argc, sizeof(char *));
  if (!frames) return 1;
  int count = 0, status = 1;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "-lossy")) lossless = 0;
    else if (!strcmp(argv[i], "-lossless")) lossless = 1;
    else if (!strcmp(argv[i], "-d") && i + 1 < argc) delay = number(argv[++i], 1, 60000);
    else if (!strcmp(argv[i], "-loop") && i + 1 < argc) loop = number(argv[++i], 0, 65535);
    else if (!strcmp(argv[i], "-q") && i + 1 < argc) quality = number(argv[++i], 1, 100);
    else if (!strcmp(argv[i], "-o") && i + 1 < argc) destination = argv[++i];
    else if (argv[i][0] == '-') { fprintf(stderr, "Unsupported option: %s\n", argv[i]); goto done; }
    else frames[count++] = argv[i];
  }
  if (!count || !destination || delay < 0 || quality < 0 || loop < 0 || count > INT_MAX / delay) {
    fprintf(stderr, "Usage: img2webp [-lossy] [-q 1..100] [-d milliseconds] [-loop count] frames.png... -o output.webp\n"); goto done;
  }
  WebPAnimEncoderOptions options;
  if (!WebPAnimEncoderOptionsInit(&options)) goto done;
  options.anim_params.loop_count = loop;
  WebPAnimEncoder *encoder = NULL;
  WebPConfig config;
  if (!WebPConfigInit(&config)) goto done;
  config.lossless = lossless; config.quality = quality; config.method = 4;
  int width = 0, height = 0;
  for (int i = 0; i < count; ++i) {
    CGImageRef image = load(frames[i]);
    if (!image) { fprintf(stderr, "Unable to read frame %d\n", i); goto cleanup; }
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w < 1 || h < 1 || w > 16383 || h > 16383 || w > 80000000 / h) { CGImageRelease(image); goto cleanup; }
    if (!encoder) { width = (int)w; height = (int)h; encoder = WebPAnimEncoderNew(width, height, &options); }
    if (!encoder || w != (size_t)width || h != (size_t)height) { CGImageRelease(image); goto cleanup; }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); goto cleanup; }
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image); CGImageRelease(image);
    uint8_t *rgba = CGBitmapContextGetData(context);
    for (size_t pixel = 0; pixel < w * h; ++pixel) {
      unsigned a = rgba[pixel * 4 + 3];
      if (a && a < 255) for (int c = 0; c < 3; ++c) rgba[pixel * 4 + c] = (uint8_t)((rgba[pixel * 4 + c] * 255u + a / 2) / a);
    }
    WebPPicture picture;
    WebPPictureInit(&picture); picture.width = width; picture.height = height; picture.use_argb = 1;
    int ok = WebPPictureImportRGBA(&picture, rgba, width * 4);
    CGContextRelease(context);
    if (ok) ok = WebPAnimEncoderAdd(encoder, &picture, i * delay, &config);
    WebPPictureFree(&picture);
    if (!ok) { fprintf(stderr, "WebP encoding failed: %s\n", WebPAnimEncoderGetError(encoder)); goto cleanup; }
  }
  if (!WebPAnimEncoderAdd(encoder, NULL, count * delay, NULL)) goto cleanup;
  WebPData data; WebPDataInit(&data);
  if (WebPAnimEncoderAssemble(encoder, &data)) {
    FILE *file = fopen(destination, "wb");
    if (file) { size_t written = fwrite(data.bytes, 1, data.size, file); int closed = fclose(file); if (written == data.size && !closed) status = 0; }
  }
  WebPDataClear(&data);
cleanup:
  if (encoder) WebPAnimEncoderDelete(encoder);
done:
  free(frames);
  return status;
}
