// Imports a PNG through pdfio's exported API. Library target, so this is the
// real public surface: pdfioFileCreate() + pdfioFileCreateImageObjFromFile().
// No pdfio-internal function is called.
//
// Exit codes: 0 = object created; 2 = create/open failure.
#include <pdfio.h>
#include <pdfio-content.h>
#include <stdio.h>

int main(int argc, char *argv[])
{
  pdfio_file_t *pdf;
  pdfio_obj_t  *img;

  if (argc < 3)
  {
    fprintf(stderr, "usage: %s IMAGE.png OUT.pdf\n", argv[0]);
    return 2;
  }

  pdf = pdfioFileCreate(argv[2], NULL, NULL, NULL, NULL, NULL);
  if (!pdf)
  {
    puts("pdfioFileCreate failed");
    return 2;
  }

  fputs("calling pdfioFileCreateImageObjFromFile...\n", stdout);
  fflush(stdout);

  img = pdfioFileCreateImageObjFromFile(pdf, argv[1], /*interpolate*/false);
  printf("image obj = %p\n", (void *)img);

  pdfioFileClose(pdf);
  return img ? 0 : 2;
}
