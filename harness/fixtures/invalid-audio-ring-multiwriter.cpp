bool Producer::OpenOrCreate() {
    StoreRelease(&buffer_->read_index, 0);
    return true;
}

bool Producer::WriteFloat32() {
    StoreSample(buffer_, 0, 0.0F);
    return true;
}

std::uint64_t Producer::ConsumedFrames() const noexcept {
    return 0;
}
