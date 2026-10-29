#include "disc_seek_index.h"
#include <iostream>
#include <stdexcept>
// This executable tests the production validator. Read-only playlist traversal
// is separately compiled with the actual pinned parser by build_native_host.py.
extern "C" int yd_visit_playlist_clpi(BLURAY *, uint32_t, void *, yd_clpi_visitor) { return 0; }
struct Fixture {
    CLPI_CL cl{};
    CLPI_ATC_SEQ atc{};
    CLPI_STC_SEQ stc{};
    CLPI_EP_MAP_ENTRY entry[2]{};
    CLPI_EP_COARSE coarse[2]{};
    CLPI_EP_FINE fine[4]{};
    Fixture() {
        cl.clip.num_source_packets = 200000;
        cl.sequence.num_atc_seq = 1; cl.sequence.atc_seq = &atc;
        atc.num_stc_seq = 1; atc.stc_seq = &stc;
        stc.presentation_start_time = 0; stc.presentation_end_time = 1000000;
        cl.cpi.type = 1; cl.cpi.num_stream_pid = 1; cl.cpi.entry = entry;
        entry[0].pid = 4113; entry[0].num_ep_coarse = 2;
        entry[0].num_ep_fine = 4; entry[0].coarse = coarse; entry[0].fine = fine;
        coarse[0] = {0, 0, 0}; coarse[1] = {2, 2, 131072};
        fine[0].pts_ep = 0; fine[0].spn_ep = 0;
        fine[1].pts_ep = 100; fine[1].spn_ep = 500;
        fine[2].pts_ep = 0; fine[2].spn_ep = 2;
        fine[3].pts_ep = 100; fine[3].spn_ep = 502;
    }
    bool valid(uint16_t pid = 4113, uint8_t id = 0) {
        std::vector<DiscSeekPoint> points;
        return disc_seek_points(&cl, pid, id, points);
    }
};
int main() {
    int count = 0;
    auto check = [&](const char *name, bool ok) {
        if (!ok) throw std::runtime_error(name);
        ++count; std::cout << "PASS " << name << '\n';
    };
    { Fixture f; std::vector<DiscSeekPoint> p;
      check("valid two-coarse map", disc_seek_points(&f.cl,4113,0,p));
      check("45k presentation points to 90k without DTS synthesis", p[1].pts90k==51200 && p[2].pts90k==1048576 && p[3].spn==131574); }
    { Fixture f; f.cl.sequence.num_atc_seq=2; check("multiple ATC fallback",!f.valid()); }
    { Fixture f; f.atc.num_stc_seq=2; check("multiple STC fallback",!f.valid()); }
    { Fixture f; check("wrong STC identity fallback",!f.valid(4113,1)); }
    { Fixture f; check("wrong video PID fallback",!f.valid(4114)); }
    { Fixture f; f.cl.cpi.num_stream_pid=2; f.entry[1]=f.entry[0]; check("duplicate PID maps fallback",!f.valid()); }
    { Fixture f; f.stc.presentation_end_time=0; check("wrapped sequence fallback",!f.valid()); }
    { Fixture f; f.entry[0].num_ep_fine=65537; check("entry count bound before pointer access",!f.valid()); }
    { Fixture f; f.coarse[0].ref_ep_fine_id=1; check("missing fine prefix fallback",!f.valid()); }
    { Fixture f; f.coarse[1].ref_ep_fine_id=0; check("reversed coarse bounds fallback",!f.valid()); }
    { Fixture f; f.coarse[1].ref_ep_fine_id=5; check("coarse beyond fine bound fallback",!f.valid()); }
    { Fixture f; f.coarse[0].pts_ep=-1; check("negative coarse time fallback",!f.valid()); }
    { Fixture f; f.fine[0].pts_ep=2048; check("fine time overflow fallback",!f.valid()); }
    { Fixture f; f.fine[0].spn_ep=-1; check("negative packet fallback",!f.valid()); }
    { Fixture f; f.fine[0].spn_ep=131072; check("fine packet overflow fallback",!f.valid()); }
    { Fixture f; f.coarse[1].spn_ep=0; check("packet order fallback",!f.valid()); }
    { Fixture f; f.fine[1].pts_ep=0; check("duplicate presentation time fallback",!f.valid()); }
    { Fixture f; f.cl.clip.num_source_packets=100; check("packet outside clip fallback",!f.valid()); }
    { Fixture f; f.stc.spn_stc_start=1; check("packet before sequence fallback",!f.valid()); }
    { Fixture f; f.stc.presentation_start_time=255; check("quantized first point allowed",f.valid()); }
    { Fixture f; f.stc.presentation_start_time=256; check("point before sequence beyond quantization fallback",!f.valid()); }
    { Fixture f; f.stc.presentation_end_time=50000; check("point after sequence fallback",!f.valid()); }
    { Fixture f; f.cl.cpi.entry=nullptr; check("missing CPI fallback",!f.valid()); }
    { Fixture f; const std::set<std::string> allowed{"00001"}; DiscSeekListing l{allowed,{},{},false};
      disc_seek_visit(&l,2,4113,0,&f.cl); check("foreign clip omitted",l.json.empty());
      disc_seek_visit(&l,1,4113,0,&f.cl); const auto original=l.json;
      check("valid JSON field units",original.find("\"points\":[[0,0],[51200,500],[1048576,131074]")!=std::string::npos);
      disc_seek_visit(&l,1,4113,0,&f.cl); check("repeat clip emitted once",l.json==original); }
    { Fixture f; const std::set<std::string> allowed{"00001"}; DiscSeekListing l{allowed,{},std::string(4*1024*1024,'x'),false};
      disc_seek_visit(&l,1,4113,0,&f.cl); check("aggregate JSON overflow clears complete result",l.overflow && l.json.empty()); }
    std::cout << "TOTAL " << count << '\n';
}
