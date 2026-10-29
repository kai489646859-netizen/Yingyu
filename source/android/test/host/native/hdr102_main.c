
int main(void){
 int passed=0, failed=0;
 for(int transfer=0;transfer<2;transfer++)for(int scenario=0;scenario<5;scenario++){
  global_api=scenario==0;local_api=scenario!=2;failed_set=scenario==3;wrong_get=scenario==4;
  uninit_count=space_seen=opens=closes=0;window.dataspace=0;stage[0]=0;
  struct options opts={17};struct vo vo={&opts};struct fns fns={transfer?"android-hdr-hlg":"android-hdr-pq"};
  struct ra_ctx ctx={.fns=&fns,.vo=&vo};
  bool actual=yingyu_hdr_init(&ctx),expected=scenario<=1;
  if(actual==expected){passed++;}else{failed++;}
  printf("%s %s scenario=%d expected=%d actual=%d stage=%s\n",actual==expected?"PASS":"FAIL",transfer?"HLG":"PQ",scenario,expected,actual,stage);
  free(ctx.priv);
 }
 printf("actual production HDR initializer: %d passed, %d behavioral failures; fake loader/EGL, no device pixels\n",passed,failed);
 return failed?1:0;
}
