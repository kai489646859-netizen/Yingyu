#include "android/app/src/main/cpp/disc_metadata.h"
#include "android/app/src/main/cpp/disc_seek_index.h"
#include "dependencies/dolby/disc_seek_index.h"
#include <iostream>
#include <cstdlib>
int main(int argc,char **argv) {
    if(argc==3 && std::string(argv[1])=="--consumer") {
        int64_t offset=-1;
        const bool ok=yd_index_offset(argv[2],"yingyu-disc://fixture/clip/00001.m2ts",4113,200000*192,12.0,&offset);
        if(!ok) return 3;
        std::cout<<offset<<'\n';return 0;
    }
    if(argc!=2) return 2;
    BLURAY *bd=bd_open(argv[1],nullptr);
    if(!bd) return 4;
    const auto titles=disc_titles(bd);
    if(titles.empty()) { bd_close(bd);return 5; }
    const auto result=disc_seek_index(bd,0,{"00001"});
    bd_close(bd);
    std::cout<<result<<'\n';
}
