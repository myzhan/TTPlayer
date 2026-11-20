#pragma once
#include <QString>
#include <deque>
#include <algorithm>

// Explicit clocks make the 30-second window deterministic in tests.
struct RadioQuality {
    static constexpr double windowSeconds=30, lowBufferSeconds=0.2;
    int session=0,totalUnderruns=0,totalReconnects=0;
    double bufferedSeconds=0;
    bool starved=false;
    std::deque<double> underrunAt,reconnectAt;
    void startSession(int id){*this=RadioQuality{};session=id;}
    void trim(double now){
        while(!underrunAt.empty()&&underrunAt.front()<=now-windowSeconds)underrunAt.pop_front();
        while(!reconnectAt.empty()&&reconnectAt.front()<=now-windowSeconds)reconnectAt.pop_front();
    }
    void noteBuffer(double seconds,double now){bufferedSeconds=std::max(0.0,seconds);if(bufferedSeconds>=lowBufferSeconds)starved=false;trim(now);}
    void noteUnderrun(double now){if(starved)return;starved=true;++totalUnderruns;underrunAt.push_back(now);trim(now);}
    void noteReconnect(double now){++totalReconnects;reconnectAt.push_back(now);trim(now);}
    int windowUnderruns(double now)const{return int(std::count_if(underrunAt.begin(),underrunAt.end(),[now](double at){return at>now-windowSeconds;}));}
    int windowReconnects(double now)const{return int(std::count_if(reconnectAt.begin(),reconnectAt.end(),[now](double at){return at>now-windowSeconds;}));}
    bool isBufferLow()const{return starved||bufferedSeconds<lowBufferSeconds;}
    QString summary(double now)const{
        if(!session)return QStringLiteral("没有正在连的电台");
        return QStringLiteral("近 30 秒欠载 %1 次、重连 %2 次；当前缓冲 %3 秒%4；本次收听累计欠载 %5 次、重连 %6 次")
            .arg(windowUnderruns(now)).arg(windowReconnects(now)).arg(bufferedSeconds,0,'f',1)
            .arg(starved?QStringLiteral("（已经排空，正在等数据）"):QString()).arg(totalUnderruns).arg(totalReconnects);
    }
};
