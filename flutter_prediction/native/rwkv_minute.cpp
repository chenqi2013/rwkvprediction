// Experimental CPU port of the pinned RWKV7 numeric forecast architecture.
// See THIRD_PARTY_NOTICES.md. No Python, network, CUDA or language-model head.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>
#if defined(__APPLE__) && !defined(RWKV_PORTABLE)
#include <Accelerate/Accelerate.h>
#endif
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default"), used))
#endif

namespace {
using V = std::vector<float>;
constexpr int T=64, C=256, D=64, H=4;
float bf(float x) {
  uint32_t bits; std::memcpy(&bits, &x, 4);
  bits += 0x7fff + ((bits >> 16) & 1);
  bits &= 0xffff0000; std::memcpy(&x, &bits, 4); return x;
}
void round_bf(V& x) { for (auto& v : x) v=bf(v); }
float sigmoid(float x) { return 1.f/(1.f+std::exp(-x)); }
struct Tensor { std::vector<uint32_t> shape; V v; };
struct Model {
  std::unordered_map<std::string, Tensor> w;
  explicit Model(const char* path) {
    auto file = std::ifstream(std::filesystem::u8path(path), std::ios::binary);
    auto read = [&](void* dst, size_t size) {
      if (!file.read(static_cast<char*>(dst), size)) throw std::runtime_error("Truncated model package");
    };
    auto integer = [&]() { uint32_t n; read(&n,4); return n; };
    char magic[8]; read(magic,8);
    if (std::memcmp(magic,"RWKV21M1",8)) throw std::runtime_error("Unsupported model package");
    auto count=integer(); if(count<10 || count>2000) throw std::runtime_error("Invalid tensor count");
    size_t total=0;
    for(uint32_t i=0; i<count; ++i) {
      auto length=integer(); if(!length || length>200) throw std::runtime_error("Invalid tensor name");
      std::string name(length,'\0'); read(name.data(),length);
      auto rank=integer(); if(rank>4) throw std::runtime_error("Invalid tensor rank");
      Tensor tensor; size_t n=1;
      for(uint32_t j=0;j<rank;++j) {
        auto dim=integer(); if(!dim || dim>65536 || n>22000000/dim) throw std::runtime_error("Invalid tensor shape");
        tensor.shape.push_back(dim); n*=dim;
      }
      total+=n; if(total>22000000) throw std::runtime_error("Oversized model");
      std::vector<uint16_t> packed(n); read(packed.data(),n*2); tensor.v.resize(n);
      for(size_t j=0;j<n;++j) {
        uint32_t bits=static_cast<uint32_t>(packed[j])<<16;
        std::memcpy(&tensor.v[j],&bits,4);
        if(!std::isfinite(tensor.v[j])) throw std::runtime_error("Non-finite weight");
      }
      if(!w.emplace(name,std::move(tensor)).second) throw std::runtime_error("Duplicate weight");
    }
    if(file.peek()!=EOF || total!=21017148) throw std::runtime_error("Wrong model size");
  }
  const V& get(const std::string& key, size_t size) const {
    auto i=w.find(key);
    if(i==w.end() || i->second.v.size()!=size) throw std::runtime_error("Missing or wrong weight: "+key);
    return i->second.v;
  }
  V mm(const V& x, const std::string& key, int in, int out, bool transpose, int rows=T, bool rounded=true) const {
    const auto& weight=get(key,static_cast<size_t>(in)*out);
    if(x.size()!=static_cast<size_t>(rows)*in) throw std::runtime_error("Invalid matrix shape");
    V y(rows*out,0);
#if defined(__APPLE__) && !defined(RWKV_PORTABLE)
    cblas_sgemm(CblasRowMajor,CblasNoTrans,transpose?CblasTrans:CblasNoTrans,
      rows,out,in,1,x.data(),in,weight.data(),transpose?in:out,0,y.data(),out);
#else
    // Row-major B, vectorizable inner loop, with exact same FP32/BF16 edges.
    V b;
    const float* data=weight.data();
    if(transpose) {
      b.resize(in*out);
      for(int k=0;k<in;++k) for(int j=0;j<out;++j) b[k*out+j]=weight[j*in+k];
      data=b.data();
    }
    for(int r=0;r<rows;++r) for(int k=0;k<in;++k) {
      float a=x[r*in+k];
      for(int j=0;j<out;++j) y[r*out+j]+=a*data[k*out+j];
    }
#endif
    auto bias=w.find(key.substr(0,key.size()-6)+"bias");
    if(transpose && key.size()>7 && key.substr(key.size()-7)==".weight" && bias!=w.end()) {
      if(bias->second.v.size()!=static_cast<size_t>(out)) throw std::runtime_error("Invalid bias");
      for(int r=0;r<rows;++r) for(int j=0;j<out;++j) y[r*out+j]+=bias->second.v[j];
    }
    if(rounded) round_bf(y); return y;
  }
  V norm(const V& x,const std::string& p) const {
    const auto& scale=get(p+".weight",C); const auto& bias=get(p+".bias",C);
    V y(x.size());
    for(int t=0;t<T;++t) {
      double mean=0,var=0; for(int j=0;j<C;++j) mean+=x[t*C+j]; mean/=C;
      for(int j=0;j<C;++j) { double z=x[t*C+j]-mean; var+=z*z; }
      float inv=1/std::sqrt(var/C+1e-5);
      for(int j=0;j<C;++j) y[t*C+j]=bf((x[t*C+j]-mean)*inv*scale[j]+bias[j]);
    } return y;
  }
  V mix(const V& x,const std::string& p) const {
    const auto& coefficient=get(p,C); V y(x.size());
    for(int t=0;t<T;++t) for(int j=0;j<C;++j) {
      float current=x[t*C+j], previous=t?x[(t-1)*C+j]:0;
      y[t*C+j]=bf(current+(previous-current)*coefficient[j]);
    } return y;
  }
  V lowrank(const V& x,const std::string& p,char kind) const {
    int rank=kind=='g'?64:32; std::string k(1,kind);
    auto y=mm(x,p+k+"1",C,rank,false);
    if(kind=='w' || kind=='g') {
      for(auto& a:y) a=bf(kind=='w'?std::tanh(a):sigmoid(a));
    }
    y=mm(y,p+k+"2",rank,C,false);
    if(kind=='w' || kind=='a') {
      const auto& bias=get(p+k+"0",C);
      for(size_t i=0;i<y.size();++i) y[i]=bf(kind=='a'?sigmoid(y[i]+bias[i%C]):y[i]+bias[i%C]);
    }
    return y;
  }
  V predict(const float* features) const {
    const auto& mean=get("feature_mean",23); const auto& std=get("feature_std",23);
    V x(T*23);
    for(int i=0;i<T*23;++i) {
      if(!std::isfinite(features[i]) || std[i%23]<=0) throw std::runtime_error("Invalid features");
      x[i]=bf((features[i]-mean[i%23])/std[i%23]);
    }
    x=mm(x,"input_projection.weight",23,C,true);
    x=norm(x,"hf.embedding_norm"); V first;
    for(int layer=0;layer<24;++layer) {
      const auto prefix="hf.layers."+std::to_string(layer)+".";
      const auto p=prefix+"linear_attn.";
      auto z=norm(x,prefix+"input_layernorm");
      auto r=mm(mix(z,p+"x_r"),p+"r_proj.weight",C,C,true);
      auto k=mm(mix(z,p+"x_k"),p+"k_proj.weight",C,C,true);
      auto v=mm(mix(z,p+"x_v"),p+"v_proj.weight",C,C,true);
      auto logits=lowrank(mix(z,p+"x_w"),p,'w');
      auto rate=lowrank(mix(z,p+"x_a"),p,'a');
      auto gate=lowrank(mix(z,p+"x_g"),p,'g');
      if(layer==0) first=v;
      else {
        auto blend=lowrank(mix(z,p+"x_v"),p,'v'); const auto& bias=get(p+"v0",C);
        for(int i=0;i<T*C;++i) v[i]=bf(v[i]+(first[i]-v[i])*sigmoid(bias[i%C]+blend[i]));
      }
      const auto& kk=get(p+"k_k",C); const auto& ka=get(p+"k_a",C);
      V a(T*C),b(T*C);
      for(int t=0;t<T;++t) for(int h=0;h<H;++h) {
        float length=0;
        for(int j=0;j<D;++j) { int i=t*C+h*D+j; float d=k[i]*kk[h*D+j]; length+=d*d; }
        length=std::max(std::sqrt(length),1e-12f);
        for(int j=0;j<D;++j) {
          int i=t*C+h*D+j; float d=k[i]*kk[h*D+j]/length;
          a[i]=bf(-d); b[i]=bf(d*rate[i]); k[i]=bf(k[i]*(1+(rate[i]-1)*ka[h*D+j]));
        }
      }
      V recurrent(T*C),state(H*D*D,0);
      for(int t=0;t<T;++t) for(int h=0;h<H;++h) {
        float dot[D]={0}; const int base=t*C+h*D;
        for(int key=0;key<D;++key) for(int value=0;value<D;++value)
          dot[value]+=state[(h*D+key)*D+value]*a[base+key];
        for(int key=0;key<D;++key) {
          float decay=std::exp(-std::exp(-.5f)*sigmoid(logits[base+key]));
          for(int value=0;value<D;++value) {
            auto& s=state[(h*D+key)*D+value];
            s=decay*s+b[base+key]*dot[value]+k[base+key]*v[base+value];
            recurrent[base+value]+=s*r[base+key];
          }
        }
      }
      round_bf(recurrent);
      const auto& gn=get(p+"g_norm.weight",C); const auto& gb=get(p+"g_norm.bias",C); const auto& rk=get(p+"r_k",C);
      V readout(T*C);
      for(int t=0;t<T;++t) for(int h=0;h<H;++h) {
        int base=t*C+h*D; float m=0,var=0,residual=0;
        for(int j=0;j<D;++j) { m+=recurrent[base+j]; residual+=r[base+j]*k[base+j]*rk[h*D+j]; } m/=D;
        for(int j=0;j<D;++j) { float d=recurrent[base+j]-m; var+=d*d; }
        float inv=1/std::sqrt(var/D+.00064f);
        for(int j=0;j<D;++j) {
          int i=base+j;
          float normalized=(recurrent[i]-m)*inv*gn[h*D+j]+gb[h*D+j];
          readout[i]=bf((normalized+residual*v[i])*gate[i]);
        }
      }
      auto out=mm(readout,p+"o_proj.weight",C,C,true);
      for(int i=0;i<T*C;++i) x[i]=bf(x[i]+out[i]);
      z=mix(norm(x,prefix+"post_attention_layernorm"),prefix+"mlp.x_k");
      z=mm(z,prefix+"mlp.key.weight",C,1024,true);
      for(auto& value:z) { value=std::max(0.f,value); value=bf(value*value); }
      z=mm(z,prefix+"mlp.value.weight",1024,C,true);
      for(int i=0;i<T*C;++i) x[i]=bf(x[i]+z[i]);
    }
    x=norm(x,"hf.norm"); V last(x.end()-C,x.end());
    auto output=mm(last,"output_projection.weight",C,270,true,1,false);
    for(auto v:output) if(!std::isfinite(v)) throw std::runtime_error("Non-finite forecast");
    return output;
  }
};
}

API int rwkv_minute_predict(const char* path,const float* features,float* output,char* error,int capacity) {
  try {
    if(!path || !features || !output) throw std::runtime_error("Null input");
    Model model(path); auto result=model.predict(features);
    std::copy(result.begin(),result.end(),output); return 0;
  } catch(const std::exception& e) {
    if(error && capacity>0) std::snprintf(error,capacity,"%s",e.what()); return -1;
  } catch(...) {
    if(error && capacity>0) std::snprintf(error,capacity,"Native inference failed"); return -1;
  }
}
