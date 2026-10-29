#include <assert.h>
#include <stdio.h>
/* PRODUCTION_PROOF_HEADER */
static int checks;
#define CHECK(x) do {assert(x);checks++;} while(0)
int main(void) {
    const char *a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const char *da="output + Yingyu Dolby gain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *db="output + Yingyu Dolby gain bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    struct yy_enhancement_proof p={0};
    yy_proof_begin(&p,"",true);yy_proof_dispatch(&p,"output to screen");
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(!p.tracking && p.frame==0 && !p.valid);
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);
    CHECK(p.frame==0 && !p.valid && p.pending);
    yy_proof_presented(&p,true);
    CHECK(p.frame==1 && p.valid && strcmp(p.shader,a)==0);
    yy_proof_presented(&p,true);
    CHECK(p.frame==1);
    yy_proof_begin(&p,b,true);yy_proof_dispatch(&p,db);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==2 && strcmp(p.shader,b)==0);
    yy_proof_begin(&p,a,true);
    // Historical performance rows aren't passed to this draw's callback.
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==2 && !p.valid);
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,db);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==2 && !p.valid);
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,false);yy_proof_presented(&p,true);
    CHECK(p.frame==2 && !p.valid);
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,false);
    CHECK(p.frame==2 && !p.valid);
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,da);
    yy_proof_dispatch(&p,db);yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==2 && !p.valid);
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==3 && p.valid && strcmp(p.shader,a)==0);
    yy_proof_begin(&p,"",true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==3 && !p.valid);
    yy_proof_begin(&p,"",true);yy_proof_dispatch(&p,"output to screen");
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==4 && p.valid && p.shader[0]=='\0');
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);yy_proof_invalidate(&p);yy_proof_presented(&p,true);
    CHECK(p.frame==4 && !p.valid && !p.pending && !p.observing);
    yy_proof_begin(&p,a,false);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==4 && !p.valid);
    yy_proof_begin(&p,"x",true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==4 && !p.valid);
    struct yy_enhancement_proof replacement={0};
    yy_proof_begin(&replacement,a,true);yy_proof_dispatch(&replacement,da);
    yy_proof_rendered(&replacement,true);yy_proof_presented(&replacement,true);
    CHECK(replacement.frame==5 && replacement.valid);
    p.frame=INT64_MAX;
    atomic_store(&yy_proof_sequence,INT64_MAX);
    yy_proof_begin(&p,a,true);yy_proof_dispatch(&p,da);
    yy_proof_rendered(&p,true);yy_proof_presented(&p,true);
    CHECK(p.frame==INT64_MAX && !p.valid);
    printf("{\"checks\":%d,\"pass\":true}\n",checks);
    return 0;
}
